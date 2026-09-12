const std = @import("std");
const rt = @import("zig_runtime");
const stdlib = @import("zig_stdlib");
const ustring_lib = @import("zig_ustring.zig");
const html_lib = @import("zig_html.zig");
const text_lib = @import("zig_text.zig");
const title_lib = @import("zig_title.zig");
const language_lib = @import("zig_language.zig");
const frame_lib = @import("zig_frame.zig");
const uri_lib = @import("zig_uri.zig");
const basics_lib = @import("zig_mw_basics.zig");
pub const FrameArg = frame_lib.FrameArg;
pub fn makeFrame(runtime: *rt.Context, title: []const u8, args: []const FrameArg, parent: ?Value) !Value {
    return frame_lib.makeFrame(runtime, title, args, parent);
}
pub fn invoke(runtime: *rt.Context, module_name: []const u8, function_name: []const u8, frame: Value) anyerror![]const Value {
    return frame_lib.invoke(runtime, module_name, function_name, frame);
}
const host_api = @import("zig_host.zig");
pub const Host = host_api.Host;
pub fn setHost(runtime: *rt.Context, host: ?*Host) void {
    host_api.set(runtime, host);
}
const Value = rt.Value;

const State = struct {
    allocator: std.mem.Allocator,
    env_slot: u32,
    string_slot: u32,
    mw_slot: u32,
    load_data_cache: std.AutoHashMapUnmanaged(u32, Value) = .empty,
    load_data_loading: std.AutoHashMapUnmanaged(u32, void) = .empty,
};

fn one(value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

fn cloneValue(a: std.mem.Allocator, value: Value, seen: *std.AutoHashMapUnmanaged(*rt.Table, *rt.Table)) !Value {
    if (value != .table) return value;
    if (seen.get(value.table)) |old| return .{ .table = old };
    const copy = try a.create(rt.Table);
    copy.* = .{};
    try seen.put(a, value.table, copy);
    var it = value.table.iterator();
    while (it.next()) |entry| {
        const key = try cloneValue(a, entry.key_ptr.*, seen);
        const item = try cloneValue(a, entry.value_ptr.*, seen);
        try copy.rawSet(a, key, item);
    }
    copy.append_index = value.table.append_index;
    if (value.table.metatable) |mt|
        copy.metatable = (try cloneValue(a, .{ .table = mt }, seen)).table;
    return .{ .table = copy };
}

fn promoteLoadData(a: std.mem.Allocator, value: Value, seen: *std.AutoHashMapUnmanaged(*rt.Table, *rt.Table)) !Value {
    return switch (value) {
        .nil, .boolean, .number => value,
        .string => |text| .{ .string = try a.dupe(u8, text) },
        .callable => error.LoadDataUnsupportedValue,
        .table => |source| blk: {
            if (source.metatable != null) return error.LoadDataMetatable;
            if (seen.get(source)) |existing| break :blk .{ .table = existing };
            const copy = try a.create(rt.Table);
            copy.* = .{};
            try seen.put(a, source, copy);
            var it = source.iterator();
            while (it.next()) |entry| {
                const key = try promoteLoadData(a, entry.key_ptr.*, seen);
                const item = try promoteLoadData(a, entry.value_ptr.*, seen);
                try copy.rawSet(a, key, item);
            }
            copy.append_index = source.append_index;
            copy.read_only = true;
            break :blk .{ .table = copy };
        },
    };
}

fn cloneCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0) return one(.nil);
    var seen: std.AutoHashMapUnmanaged(*rt.Table, *rt.Table) = .empty;
    defer seen.deinit(runtime.allocator);
    return one(try cloneValue(runtime.allocator, args[0], &seen));
}

fn installStringAliases(runtime: *rt.Context, string: *rt.Table, ustring: *rt.Table) !void {
    inline for (.{
        .{ "isutf8", "isutf8" },         .{ "byteoffset", "byteoffset" }, .{ "codepoint", "codepoint" },
        .{ "gcodepoint", "gcodepoint" }, .{ "toNFC", "toNFC" },           .{ "toNFD", "toNFD" },
        .{ "uchar", "char" },            .{ "ulen", "len" },              .{ "usub", "sub" },
        .{ "uupper", "upper" },          .{ "ulower", "lower" },          .{ "ufind", "find" },
        .{ "umatch", "match" },          .{ "ugmatch", "gmatch" },        .{ "ugsub", "gsub" },
    }) |entry| {
        const value = ustring.rawGet(.{ .string = entry[1] }) orelse return error.MissingUstringFunction;
        try string.rawSet(runtime.allocator, .{ .string = entry[0] }, value);
    }
}

fn installInto(runtime: *rt.Context, state: *State) !void {
    const mw = try runtime.newNativeNamespace(.mw);
    const ustring = try runtime.newNativeNamespace(.ustring);
    const string = runtime.getGlobal(state.string_slot);
    if (string != .table) return error.MissingStringLibrary;
    var it = string.table.iterator();
    while (it.next()) |entry|
        try ustring.rawSet(runtime.allocator, entry.key_ptr.*, entry.value_ptr.*);
    try ustring_lib.install(runtime, ustring);
    try html_lib.install(runtime, mw);
    try installStringAliases(runtime, string.table, ustring);
    try mw.rawSet(runtime.allocator, .{ .string = "ustring" }, .{ .table = ustring });
    try text_lib.install(runtime, mw);
    try title_lib.install(runtime, mw);
    try language_lib.install(runtime, mw);
    try frame_lib.install(runtime, mw);
    try uri_lib.install(runtime, mw);
    try basics_lib.install(runtime, mw);
    try mw.rawSet(runtime.allocator, .{ .string = "loadData" }, try runtime.newNative(state, loadDataCall));
    try mw.rawSet(runtime.allocator, .{ .string = "clone" }, try runtime.newNative(null, cloneCall));
    try runtime.setGlobal(state.mw_slot, .{ .table = mw });
}
fn loadDataCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.ModuleNameExpected;
    const state: *State = @ptrCast(@alignCast(raw orelse return error.MissingScribuntoState));
    const module_id = try runtime.resolveModule(args[0].string);
    if (state.load_data_cache.get(module_id)) |value| return one(value);
    if (state.load_data_loading.contains(module_id)) return error.LoadDataLoop;
    try state.load_data_loading.put(state.allocator, module_id, {});
    defer _ = state.load_data_loading.remove(module_id);

    var eval_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer eval_arena.deinit();
    var child = try runtime.forkProgram(eval_arena.allocator());
    defer child.deinit();
    const global_shape = if (runtime.global_table) |global| global.shape else null;
    try rt.bindGlobalTable(&child, global_shape, state.env_slot);
    try stdlib.install(&child);
    try installInto(&child, state);
    const empty_args = try child.newTable();
    const empty_frame = try frame_lib.makeFrameFromTable(&child, "empty", empty_args, null);
    child.current_frame = empty_frame.table;
    const source = child.requireByName(args[0].string) catch |err| {
        runtime.adoptFailure(&child);
        return err;
    };

    var seen: std.AutoHashMapUnmanaged(*rt.Table, *rt.Table) = .empty;
    defer seen.deinit(eval_arena.allocator());
    const promoted = try promoteLoadData(state.allocator, source, &seen);
    try state.load_data_cache.put(state.allocator, module_id, promoted);
    return one(promoted);
}
pub fn install(runtime: *rt.Context, env_slot: u32, string_slot: u32, mw_slot: u32) !void {
    const state = try runtime.allocator.create(State);
    state.* = .{
        .allocator = runtime.allocator,
        .env_slot = env_slot,
        .string_slot = string_slot,
        .mw_slot = mw_slot,
    };
    try installInto(runtime, state);
}
fn installForExpander(
    raw_state: *?*anyopaque,
    page_allocator: std.mem.Allocator,
    runtime: *rt.Context,
    env_slot: u32,
    string_slot: u32,
    mw_slot: u32,
) !void {
    const state: *State = if (raw_state.*) |raw|
        @ptrCast(@alignCast(raw))
    else blk: {
        const created = try page_allocator.create(State);
        created.* = .{
            .allocator = page_allocator,
            .env_slot = env_slot,
            .string_slot = string_slot,
            .mw_slot = mw_slot,
        };
        raw_state.* = created;
        break :blk created;
    };
    if (state.env_slot != env_slot or state.string_slot != string_slot or state.mw_slot != mw_slot)
        return error.ScribuntoStateSlotMismatch;
    try installInto(runtime, state);
}

fn callField(runtime: *rt.Context, object: Value, name: []const u8, args: []const Value) ![]const Value {
    const callable = try runtime.getIndex(object, .{ .string = name });
    return runtime.callValue(callable, args);
}

test "AOT Scribunto installs mw.ustring, html, loadData, clone, and string aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 3);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try runtime.setGlobal(1, .{ .table = try runtime.newTable() });
    try install(&runtime, 0, 1, 2);
    const mw = runtime.getGlobal(2);
    try std.testing.expect(mw == .table);
    const ustring = try runtime.getIndex(mw, .{ .string = "ustring" });
    try std.testing.expect(ustring == .table);
    const len = try callField(&runtime, ustring, "len", &.{.{ .string = "hé猫" }});
    defer rt.freeResults(len);
    try std.testing.expectEqual(@as(f64, 3), len[0].number);
    const string = runtime.getGlobal(1);
    const alias = try runtime.getIndex(string, .{ .string = "ulen" });
    const direct = try runtime.getIndex(ustring, .{ .string = "len" });
    try std.testing.expect(rt.rawEqual(alias, direct));
    try std.testing.expect((try runtime.getIndex(mw, .{ .string = "html" })) == .table);
    try std.testing.expect((try runtime.getIndex(mw, .{ .string = "loadData" })) == .callable);
    try std.testing.expect((try runtime.getIndex(mw, .{ .string = "clone" })) == .callable);
}

const DataProbe = struct {
    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        if (std.mem.eql(u8, raw_name, "Module:Data")) return 0;
        if (std.mem.eql(u8, raw_name, "Module:DataFail")) return 1;
        return null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return switch (id) {
            0 => "Module:Data",
            1 => "Module:DataFail",
            else => null,
        };
    }
    fn root(runtime: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        if (runtime.current_frame == null) return error.MissingLoadDataFrame;
        const count = runtime.getGlobal(1);
        try runtime.setGlobal(1, .{ .number = if (count == .number) count.number + 1 else 1 });
        const nested = try runtime.newTable();
        try nested.rawSet(runtime.allocator, .{ .string = "x" }, .{ .number = 7 });
        const table = try runtime.newTable();
        try table.rawSet(runtime.allocator, .{ .string = "nested" }, .{ .table = nested });
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = table };
        return out;
    }
    fn fail(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        return error.NotCallable;
    }
};

test "AOT loadData runs in an isolated context and promotes a cached read-only graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 2);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(DataProbe.root), rt.stabilize(DataProbe.fail) };
    const roots = [_]u32{ 0, 1 };
    runtime.module_roots = &roots;
    runtime.module_root_entries = &.{ &functions[0], &functions[1] };
    runtime.configureModules(null, DataProbe.lookup, DataProbe.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try install(&runtime, 0, 18, 23);
    try runtime.setGlobal(1, .{ .number = 40 });
    const mw = runtime.getGlobal(23);
    const first = try callField(&runtime, mw, "loadData", &.{.{ .string = "Module:Data" }});
    defer rt.freeResults(first);
    const second = try callField(&runtime, mw, "loadData", &.{.{ .string = "Module:Data" }});
    defer rt.freeResults(second);
    try std.testing.expect(first[0] == .table and second[0] == .table);
    try std.testing.expectError(error.AotCallFailed, callField(&runtime, mw, "loadData", &.{.{ .string = "Module:DataFail" }}));
    try std.testing.expectEqualStrings("NotCallable", runtime.aotErrorName().?);
    try std.testing.expect(first[0].table == second[0].table);
    try std.testing.expect(first[0].table.read_only);
    const nested = first[0].table.rawGet(.{ .string = "nested" }) orelse return error.MissingNestedData;
    try std.testing.expect(nested == .table and nested.table.read_only);
    try std.testing.expectEqual(@as(f64, 7), nested.table.rawGet(.{ .string = "x" }).?.number);
    try std.testing.expectError(error.ReadOnlyTable, first[0].table.rawSet(runtime.allocator, .{ .string = "y" }, .{ .number = 1 }));
    try std.testing.expectEqual(@as(f64, 40), runtime.getGlobal(1).number);
}

test "AOT expander loadData cache survives fresh invoke contexts" {
    var page = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer page.deinit();
    var runtime = try rt.Context.initProgram(page.allocator(), 24, 2);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(DataProbe.root), rt.stabilize(DataProbe.fail) };
    const roots = [_]u32{ 0, 1 };
    runtime.module_roots = &roots;
    runtime.module_root_entries = &.{ &functions[0], &functions[1] };
    runtime.configureModules(null, DataProbe.lookup, DataProbe.name);

    var shared_state: ?*anyopaque = null;
    var first_table: *rt.Table = undefined;
    {
        var invoke_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer invoke_arena.deinit();
        var child = try runtime.forkProgram(invoke_arena.allocator());
        defer child.deinit();
        try rt.bindGlobalTable(&child, null, 0);
        try stdlib.install(&child);
        try installForExpander(&shared_state, page.allocator(), &child, 0, 18, 23);
        const mw = child.getGlobal(23);
        const first = try callField(&child, mw, "loadData", &.{.{ .string = "Module:Data" }});
        defer rt.freeResults(first);
        try std.testing.expect(first[0] == .table and first[0].table.read_only);
        first_table = first[0].table;
    }
    {
        var invoke_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer invoke_arena.deinit();
        var child = try runtime.forkProgram(invoke_arena.allocator());
        defer child.deinit();
        try rt.bindGlobalTable(&child, null, 0);
        try stdlib.install(&child);
        try installForExpander(&shared_state, page.allocator(), &child, 0, 18, 23);
        const mw = child.getGlobal(23);
        const second = try callField(&child, mw, "loadData", &.{.{ .string = "Module:Data" }});
        defer rt.freeResults(second);
        try std.testing.expect(second[0] == .table);
        try std.testing.expect(second[0].table == first_table);
        try std.testing.expectEqual(@as(f64, 7), second[0].table.rawGet(.{ .string = "nested" }).?.table.rawGet(.{ .string = "x" }).?.number);
    }
}

test "AOT clone preserves cycles while returning mutable tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 3);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try runtime.setGlobal(1, .{ .table = try runtime.newTable() });
    try install(&runtime, 0, 1, 2);
    const source = try runtime.newTable();
    try source.rawSet(runtime.allocator, .{ .string = "self" }, .{ .table = source });
    const mw = runtime.getGlobal(2);
    const cloned = try callField(&runtime, mw, "clone", &.{.{ .table = source }});
    defer rt.freeResults(cloned);
    try std.testing.expect(cloned[0] == .table and cloned[0].table != source);
    try std.testing.expect(cloned[0].table.rawGet(.{ .string = "self" }).?.table == cloned[0].table);
    try cloned[0].table.rawSet(runtime.allocator, .{ .string = "x" }, .{ .number = 1 });
}

fn makeMovedHostContext(a: std.mem.Allocator) !rt.Context {
    var runtime = try rt.Context.init(a, 24);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try install(&runtime, 0, 18, 23);
    return runtime;
}

test "AOT host survives Context return by value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try makeMovedHostContext(arena.allocator());
    defer runtime.deinit();
    const mw = runtime.getGlobal(23);
    const html = try runtime.getIndex(mw, .{ .string = "html" });
    const made = try callField(&runtime, html, "create", &.{.{ .string = "b" }});
    defer rt.freeResults(made);
    const text = try runtime.getIndex(made[0], .{ .string = "wikitext" });
    const wrote = try runtime.callValue(text, &.{ made[0], .{ .string = "ok" } });
    defer rt.freeResults(wrote);
    const tostring = runtime.metamethod(made[0], "__tostring") orelse return error.MissingHtmlTostring;
    const rendered = try runtime.callValue(tostring, &.{made[0]});
    defer rt.freeResults(rendered);
    try std.testing.expectEqualStrings("<b>ok</b>", rendered[0].string);
}

test "AOT mw.text split and gsplit preserve Unicode and empty fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try makeMovedHostContext(arena.allocator());
    defer runtime.deinit();
    const mw = runtime.getGlobal(23);
    const text = try runtime.getIndex(mw, .{ .string = "text" });
    const split = try callField(&runtime, text, "split", &.{
        .{ .string = "α,β,,γ" },
        .{ .string = "," },
        .{ .boolean = true },
    });
    defer rt.freeResults(split);
    inline for (.{ "α", "β", "", "γ" }, 1..) |expected, index|
        try std.testing.expectEqualStrings(expected, split[0].table.rawGet(.{ .number = @floatFromInt(index) }).?.string);

    const created = try callField(&runtime, text, "gsplit", &.{ .{ .string = "가나다" }, .{ .string = "" } });
    defer rt.freeResults(created);
    const iterator = created[0];
    inline for (.{ "가", "나", "다" }) |expected| {
        const item = try runtime.callValue(iterator, &.{});
        defer rt.freeResults(item);
        try std.testing.expectEqualStrings(expected, item[0].string);
    }
    const done = try runtime.callValue(iterator, &.{});
    defer rt.freeResults(done);
    try std.testing.expectEqual(@as(usize, 0), done.len);
}

test "AOT mw.text trim listToText and nowiki match Scribunto behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try makeMovedHostContext(arena.allocator());
    defer runtime.deinit();
    const text = try runtime.getIndex(runtime.getGlobal(23), .{ .string = "text" });
    const trimmed = try callField(&runtime, text, "trim", &.{.{ .string = " \tword\n" }});
    defer rt.freeResults(trimmed);
    try std.testing.expectEqualStrings("word", trimmed[0].string);

    const list = try runtime.newTable();
    try list.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "a" });
    try list.rawSet(runtime.allocator, .{ .number = 2 }, .{ .string = "b" });
    try list.rawSet(runtime.allocator, .{ .number = 3 }, .{ .string = "c" });
    const joined = try callField(&runtime, text, "listToText", &.{.{ .table = list }});
    defer rt.freeResults(joined);
    try std.testing.expectEqualStrings("a, b and c", joined[0].string);
    inline for (.{
        .{ "[[x|y]]", "&#91;&#91;x&#124;y&#93;&#93;" },
        .{ "# item\n* two", "&#35; item\n&#42; two" },
        .{ "----\n__TOC__", "&#45;---\n_&#95;TOC_&#95;" },
        .{ "http://x ISBN 1", "http&#58;//x ISBN&#32;1" },
        .{ "mailto:x@y", "mailto&#58;x@y" },
        .{ "~abc_", "&#126;abc&#95;" },
    }) |case| {
        const escaped = try callField(&runtime, text, "nowiki", &.{.{ .string = case[0] }});
        defer rt.freeResults(escaped);
        try std.testing.expectEqualStrings(case[1], escaped[0].string);
    }
    const unstrip = try callField(&runtime, text, "unstrip", &.{.{ .string = "plain" }});
    defer rt.freeResults(unstrip);
    try std.testing.expectEqualStrings("plain", unstrip[0].string);
    const unstrip_fn = try runtime.getIndex(text, .{ .string = "unstrip" });
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(unstrip_fn, &.{.{ .string = "x\x7fy" }}));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
}

test "AOT Scribunto compiler-known namespaces use native slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try makeMovedHostContext(arena.allocator());
    defer runtime.deinit();
    const mw = runtime.getGlobal(23);
    try std.testing.expect(mw == .table and mw.table.native_namespace.? == .mw);
    inline for (.{
        .{ "title", "title" },
        .{ "text", "text" },
        .{ "uri", "uri" },
        .{ "html", "html" },
        .{ "language", "language" },
        .{ "ustring", "ustring" },
    }) |entry| {
        const value = try runtime.getIndex(mw, .{ .string = entry[0] });
        try std.testing.expect(value == .table and std.mem.eql(u8, @tagName(value.table.native_namespace.?), entry[1]));
    }

    const title_api = try runtime.getIndex(mw, .{ .string = "title" });
    const title_value = try callField(&runtime, title_api, "new", &.{.{ .string = "Template:X" }});
    defer rt.freeResults(title_value);
    try std.testing.expectEqualStrings("title_value", @tagName(title_value[0].table.native_namespace.?));
    const language_value = try callField(&runtime, mw, "getContentLanguage", &.{});
    defer rt.freeResults(language_value);
    try std.testing.expectEqualStrings("language_value", @tagName(language_value[0].table.native_namespace.?));
    const html_api = try runtime.getIndex(mw, .{ .string = "html" });
    const html_node = try callField(&runtime, html_api, "create", &.{.{ .string = "b" }});
    defer rt.freeResults(html_node);
    try std.testing.expectEqualStrings("html_node", @tagName(html_node[0].table.native_namespace.?));
    const frame = try makeFrame(&runtime, "Module:X", &.{}, null);
    try std.testing.expectEqualStrings("frame", @tagName(frame.table.native_namespace.?));
}

pub const WikitextProvider = @import("zig_wikitext.zig").Provider;
pub const WikitextExpander = @import("zig_wikitext.zig").Expander;
pub fn makeWikitextExpander(runtime: *rt.Context, env_slot: u32, string_slot: u32, mw_slot: u32, provider: WikitextProvider) WikitextExpander {
    return .{
        .runtime = runtime,
        .env_slot = env_slot,
        .string_slot = string_slot,
        .mw_slot = mw_slot,
        .provider = provider,
        .install_scribunto = installForExpander,
    };
}
