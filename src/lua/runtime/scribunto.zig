const std = @import("std");
const rt = @import("zig_runtime");
const stdlib = @import("zig_stdlib");
const global_abi = @import("lua_globals");
const ustring_lib = @import("ustring.zig");
const html_lib = @import("html.zig");
const text_lib = @import("text.zig");
const title_lib = @import("title.zig");
const language_lib = @import("language.zig");
const frame_lib = @import("frame.zig");
const uri_lib = @import("uri.zig");
const basics_lib = @import("mw_basics.zig");
const hash_lib = @import("hash.zig");
const os_lib = @import("os.zig");
pub const FrameArg = frame_lib.FrameArg;
pub fn makeFrame(runtime: *rt.Context, title: []const u8, args: []const FrameArg, parent: ?Value) !Value {
    return frame_lib.makeFrame(runtime, title, args, parent);
}
pub fn invoke(runtime: *rt.Context, module_name: []const u8, function_name: []const u8, frame: Value) anyerror![]const Value {
    return frame_lib.invoke(runtime, module_name, function_name, frame);
}
const host_api = @import("host.zig");
pub const Host = host_api.Host;
pub fn setHost(runtime: *rt.Context, host: ?*Host) void {
    host_api.set(runtime, host);
}
const Value = rt.Value;

const shared_load_data_max_entries: usize = 256;
const shared_load_data_max_bytes: usize = 64 * 1024 * 1024;
const shared_load_data_max_entry_bytes: usize = 8 * 1024 * 1024;

pub const SharedLoadDataCache = struct {
    const Entry = struct {
        arena: *std.heap.ArenaAllocator,
        value: Value,
        bytes: usize,
        hits: u64 = 0,
    };

    backing: std.mem.Allocator,
    cacheable: []const bool,
    entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
    seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    impure: std.AutoHashMapUnmanaged(u32, void) = .empty,
    dynamic_disabled: bool = false,
    metatable_arena: std.heap.ArenaAllocator,
    metatable: ?*rt.Table = null,
    bytes: usize = 0,
    hits: u64 = 0,
    promotions: u64 = 0,
    effect_exclusions: u64 = 0,
    first_promoted: [16]u32 = undefined,
    promoted_count: usize = 0,
    first_excluded: [16]u32 = undefined,
    excluded_count: usize = 0,

    pub fn init(backing: std.mem.Allocator, cacheable: []const bool) SharedLoadDataCache {
        return .{
            .backing = backing,
            .cacheable = cacheable,
            .metatable_arena = std.heap.ArenaAllocator.init(backing),
        };
    }

    pub fn deinit(self: *SharedLoadDataCache) void {
        var values = self.entries.valueIterator();
        while (values.next()) |entry| {
            entry.arena.deinit();
            self.backing.destroy(entry.arena);
        }
        self.entries.deinit(self.backing);
        self.seen.deinit(self.backing);
        self.impure.deinit(self.backing);
        self.metatable_arena.deinit();
        self.* = undefined;
    }

    fn isCacheable(self: *const SharedLoadDataCache, module_id: u32) bool {
        return module_id < self.cacheable.len and self.cacheable[module_id];
    }

    fn get(self: *SharedLoadDataCache, module_id: u32) ?Value {
        const entry = self.entries.getPtr(module_id) orelse return null;
        self.hits +|= 1;
        entry.hits +|= 1;
        return entry.value;
    }

    fn recordFirst(ids: *[16]u32, count: *usize, module_id: u32) void {
        for (ids[0..count.*]) |id| if (id == module_id) return;
        if (count.* == ids.len) return;
        ids[count.*] = module_id;
        count.* += 1;
    }

    /// Build-worker diagnostics only; emitted once when its persistent engine exits.
    pub fn logDiagnostics(self: *const SharedLoadDataCache, module_names: []const []const u8) void {
        rt.work_stats.logLine("loadData cache: hits={d} promotions={d} effect_exclusions={d} entries={d} bytes={d}\n", .{
            self.hits, self.promotions, self.effect_exclusions, self.entries.count(), self.bytes,
        });
        for (self.first_promoted[0..self.promoted_count]) |id| {
            const name = if (id < module_names.len) module_names[id] else "?";
            rt.work_stats.logLine("loadData promoted: {d} {s}\n", .{ id, name[0..@min(name.len, 512)] });
        }
        for (self.first_excluded[0..self.excluded_count]) |id| {
            const name = if (id < module_names.len) module_names[id] else "?";
            rt.work_stats.logLine("loadData effect excluded: {d} {s}\n", .{ id, name[0..@min(name.len, 512)] });
        }
        inline for (.{ "Module:scripts/data", "Module:languages/chars" }) |target| {
            for (module_names, 0..) |name, index| {
                if (!std.mem.eql(u8, name, target)) continue;
                const id: u32 = @intCast(index);
                const entry = self.entries.get(id);
                rt.work_stats.logLine("loadData target: {s} id={d} hits={d} admitted={} excluded={}\n", .{
                    target,        id,                       if (entry) |value| value.hits else @as(u64, 0),
                    entry != null, self.impure.contains(id),
                });
                break;
            }
        }
    }

    fn noteImpure(self: *SharedLoadDataCache, module_id: u32) void {
        if (self.isCacheable(module_id)) return;
        self.effect_exclusions +|= 1;
        recordFirst(&self.first_excluded, &self.excluded_count, module_id);
        // A page-sensitive execution must never be promoted after a later
        // apparently pure execution of the same module.
        self.impure.put(self.backing, module_id, {}) catch {
            self.dynamic_disabled = true;
        };
        _ = self.seen.remove(module_id);
    }

    fn loadDataMetatable(self: *SharedLoadDataCache) !*rt.Table {
        if (self.metatable) |table| return table;
        const a = self.metatable_arena.allocator();
        const table = try a.create(rt.Table);
        table.* = .{};
        try table.rawSet(a, .{ .string = "mw_loadData" }, .{ .boolean = true });
        try table.rawSet(a, .{ .string = "__metatable" }, .{ .table = table });
        table.read_only = true;
        self.metatable = table;
        return table;
    }

    fn tryPromote(self: *SharedLoadDataCache, module_id: u32, source: Value, dynamic_proven: bool) !?Value {
        if (!self.isCacheable(module_id) and
            (!dynamic_proven or self.dynamic_disabled or self.impure.contains(module_id))) return null;
        if (self.get(module_id)) |value| return value;
        if (!self.seen.contains(module_id)) {
            try self.seen.put(self.backing, module_id, {});
            return null;
        }
        if (self.entries.count() >= shared_load_data_max_entries or self.bytes >= shared_load_data_max_bytes)
            return null;

        const arena = try self.backing.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.backing);
        errdefer {
            arena.deinit();
            self.backing.destroy(arena);
        }
        const a = arena.allocator();
        const promoted = blk: {
            var seen_tables: std.AutoHashMapUnmanaged(*rt.Table, *rt.Table) = .empty;
            defer seen_tables.deinit(a);
            break :blk try promoteLoadData(a, source, &seen_tables, try self.loadDataMetatable());
        };
        const bytes = arena.queryCapacity();
        if (bytes > shared_load_data_max_entry_bytes or bytes > shared_load_data_max_bytes - self.bytes) {
            arena.deinit();
            self.backing.destroy(arena);
            return null;
        }
        try self.entries.put(self.backing, module_id, .{ .arena = arena, .value = promoted, .bytes = bytes });
        self.bytes += bytes;
        self.promotions +|= 1;
        recordFirst(&self.first_promoted, &self.promoted_count, module_id);
        return promoted;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    env_slot: u32,
    string_slot: u32,
    mw_slot: u32,
    shared_load_data: ?*SharedLoadDataCache = null,
    load_data_cache: std.AutoHashMapUnmanaged(u32, Value) = .empty,
    load_data_loading: std.AutoHashMapUnmanaged(u32, void) = .empty,
    load_json_cache: std.StringHashMapUnmanaged(Value) = .empty,
    load_data_metatable: ?*rt.Table = null,
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
        const item = try cloneValue(a, entry.value_ptr.*, seen);
        try copy.rawSet(a, entry.key_ptr.*, item);
    }
    copy.append_index = value.table.append_index;
    if (value.table.metatable) |mt|
        copy.metatable = (try cloneValue(a, .{ .table = mt }, seen)).table;
    return .{ .table = copy };
}

fn pageLoadDataMetatable(state: *State) !*rt.Table {
    if (state.load_data_metatable) |table| return table;
    if (state.shared_load_data) |shared| {
        const table = try shared.loadDataMetatable();
        state.load_data_metatable = table;
        return table;
    }
    const table = try state.allocator.create(rt.Table);
    table.* = .{};
    try table.rawSet(state.allocator, .{ .string = "mw_loadData" }, .{ .boolean = true });
    try table.rawSet(state.allocator, .{ .string = "__metatable" }, .{ .table = table });
    table.read_only = true;
    state.load_data_metatable = table;
    return table;
}

fn promoteLoadData(a: std.mem.Allocator, value: Value, seen: *std.AutoHashMapUnmanaged(*rt.Table, *rt.Table), metatable: *rt.Table) !Value {
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
                if (entry.key_ptr.* == .table) return error.LoadDataTableKey;
                const key = try promoteLoadData(a, entry.key_ptr.*, seen, metatable);
                const item = try promoteLoadData(a, entry.value_ptr.*, seen, metatable);
                try copy.rawSet(a, key, item);
            }
            copy.append_index = source.append_index;
            copy.metatable = metatable;
            copy.read_only = true;
            break :blk .{ .table = copy };
        },
    };
}

fn promoteLoadDataForState(state: *State, module_id: u32, source: Value, dynamic_proven: bool) !Value {
    if (state.shared_load_data) |shared|
        if (try shared.tryPromote(module_id, source, dynamic_proven)) |value| return value;
    var seen: std.AutoHashMapUnmanaged(*rt.Table, *rt.Table) = .empty;
    defer seen.deinit(state.allocator);
    return promoteLoadData(state.allocator, source, &seen, try pageLoadDataMetatable(state));
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
    const case_mapper = try ustring_lib.install(runtime, ustring);
    try html_lib.install(runtime, mw);
    try mw.rawSetNativeField(.mw, "ustring", .{ .table = ustring });
    try text_lib.install(runtime, mw);
    try title_lib.install(runtime, mw, case_mapper);
    try language_lib.install(runtime, mw, case_mapper);
    try installStringAliases(runtime, string.table, ustring);
    try frame_lib.install(runtime, mw);
    try uri_lib.install(runtime, mw);
    try basics_lib.install(runtime, mw);
    try hash_lib.install(runtime, mw);
    try os_lib.install(runtime);
    try mw.rawSetNativeField(.mw, "loadData", try runtime.newNative(state, loadDataCall));
    try mw.rawSetNativeField(.mw, "loadJsonData", try runtime.newNative(state, loadJsonDataCall));
    try mw.rawSetNativeField(.mw, "clone", try runtime.newNative(null, cloneCall));
    try runtime.setGlobal(state.mw_slot, .{ .table = mw });
}
fn loadDataCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    // Nested loadData uses the caller's page-local State and may see results
    // loaded earlier on this page, even when the nested module is pure.
    rt.markLoadDataEffect();
    if (args.len == 0 or args[0] != .string) return error.ModuleNameExpected;
    const state: *State = @ptrCast(@alignCast(raw orelse return error.MissingScribuntoState));
    const module_id = try runtime.resolveModule(args[0].string);
    if (state.shared_load_data) |shared| if (shared.get(module_id)) |value| return one(value);
    if (state.load_data_cache.get(module_id)) |value| return one(value);
    if (runtime.loadDataSnapshot(module_id)) |source| {
        if (source != .table) return error.LoadDataTableExpected;
        const promoted = try promoteLoadDataForState(state, module_id, source, false);
        try state.load_data_cache.put(state.allocator, module_id, promoted);
        return one(promoted);
    }
    if (state.load_data_loading.contains(module_id)) return error.LoadDataLoop;
    try state.load_data_loading.put(state.allocator, module_id, {});
    defer _ = state.load_data_loading.remove(module_id);

    var eval_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer eval_arena.deinit();
    var child = try runtime.forkProgram(eval_arena.allocator());
    defer child.deinit();
    const global_shape = if (runtime.global_table) |global| global.shape else null;
    var observed_effect = false;
    const source = blk: {
        const previous_probe = rt.beginLoadDataEffectProbe(&observed_effect);
        defer rt.endLoadDataEffectProbe(previous_probe);
        try rt.bindGlobalTable(&child, global_shape, state.env_slot);
        if (!try child.bootstrapProgram()) try stdlib.install(&child);
        try installInto(&child, state);
        const empty_args = try child.newTable();
        const empty_frame = try frame_lib.makeFrameFromTable(&child, "empty", empty_args, null);
        child.current_frame = empty_frame.table;
        break :blk child.requireByName(args[0].string) catch |err| {
            try runtime.adoptFailure(&child);
            return err;
        };
    };
    if (source != .table) return error.LoadDataTableExpected;
    if (observed_effect) if (state.shared_load_data) |shared| shared.noteImpure(module_id);

    const promoted = try promoteLoadDataForState(state, module_id, source, !observed_effect);
    try state.load_data_cache.put(state.allocator, module_id, promoted);
    return one(promoted);
}
fn loadJsonDataCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    rt.markLoadDataEffect();
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const state: *State = @ptrCast(@alignCast(raw orelse return error.MissingScribuntoState));
    const title = args[0].string;
    if (state.load_json_cache.get(title)) |value| return one(value);

    const host = host_api.get(runtime) orelse return error.NotImplemented;
    const get_model = host.page_content_model orelse return error.NotImplemented;
    const model = (try get_model(host.ctx, title)) orelse return error.InvalidJsonPage;
    if (!std.mem.eql(u8, model, "json")) return error.InvalidJsonPage;
    const get_content = host.page_content orelse return error.NotImplemented;
    const source = (try get_content(host.ctx, runtime.allocator, title)) orelse return error.InvalidJsonPage;
    if (source.len == 0) return error.InvalidJsonPage;

    const decoded = text_lib.jsonDecodeValue(runtime, source, 0) catch return error.InvalidJsonPage;
    if (decoded != .table) return error.LoadJsonDataTableExpected;
    var seen: std.AutoHashMapUnmanaged(*rt.Table, *rt.Table) = .empty;
    defer seen.deinit(state.allocator);
    const promoted = try promoteLoadData(state.allocator, decoded, &seen, try pageLoadDataMetatable(state));
    const key = try state.allocator.dupe(u8, title);
    try state.load_json_cache.put(state.allocator, key, promoted);
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
    shared_raw: ?*anyopaque,
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
            .shared_load_data = if (shared_raw) |raw| @ptrCast(@alignCast(raw)) else null,
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
    const broken = [_]u8{0xc9};
    const upper = try callField(&runtime, ustring, "upper", &.{.{ .string = &broken }});
    defer rt.freeResults(upper);
    try std.testing.expectEqualSlices(u8, &broken, upper[0].string);
    const unicode_upper = try callField(&runtime, ustring, "upper", &.{.{ .string = "éclair" }});
    defer rt.freeResults(unicode_upper);
    try std.testing.expectEqualStrings("ÉCLAIR", unicode_upper[0].string);
    const string = runtime.getGlobal(1);
    const alias = try runtime.getIndex(string, .{ .string = "ulen" });
    const direct = try runtime.getIndex(ustring, .{ .string = "len" });
    try std.testing.expect(rt.rawEqual(alias, direct));
    const string_upper = try runtime.getIndex(string, .{ .string = "uupper" });
    const broken_alias = try runtime.callValue(string_upper, &.{.{ .string = &broken }});
    defer rt.freeResults(broken_alias);
    try std.testing.expectEqualSlices(u8, &broken, broken_alias[0].string);
    try std.testing.expect((try runtime.getIndex(mw, .{ .string = "html" })) == .table);
    try std.testing.expect((try runtime.getIndex(mw, .{ .string = "loadData" })) == .callable);
    try std.testing.expect((try runtime.getIndex(mw, .{ .string = "loadJsonData" })) == .callable);
    try std.testing.expect((try runtime.getIndex(mw, .{ .string = "clone" })) == .callable);
}

const DataProbe = struct {
    var root_calls = std.atomic.Value(usize).init(0);
    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        if (std.mem.eql(u8, raw_name, "Module:Data")) return 0;
        if (std.mem.eql(u8, raw_name, "Module:DataFail")) return 1;
        if (std.mem.eql(u8, raw_name, "Module:DataScalar")) return 2;
        if (std.mem.eql(u8, raw_name, "Module:DataTableKey")) return 3;
        return null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return switch (id) {
            0 => "Module:Data",
            1 => "Module:DataFail",
            2 => "Module:DataScalar",
            3 => "Module:DataTableKey",
            else => null,
        };
    }
    fn root(runtime: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        _ = root_calls.fetchAdd(1, .monotonic);
        if (runtime.current_frame == null) return error.MissingLoadDataFrame;
        const count = runtime.getGlobal(1);
        try runtime.setGlobal(1, .{ .number = if (count == .number) count.number + 1 else 1 });
        const nested = try runtime.newTable();
        try nested.rawSet(runtime.allocator, .{ .string = "x" }, .{ .number = 7 });
        const table = try runtime.newTable();
        try table.rawSet(runtime.allocator, .{ .string = "nested" }, .{ .table = nested });
        try table.rawSet(runtime.allocator, .{ .string = "alias" }, .{ .table = nested });
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = table };
        return out;
    }
    fn pageSensitive(runtime: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        _ = root_calls.fetchAdd(1, .monotonic);
        const host = host_api.get(runtime) orelse return error.MissingScribuntoHost;
        const table = try runtime.newTable();
        try table.rawSet(runtime.allocator, .{ .string = "title" }, .{ .string = host.current_title });
        return one(.{ .table = table });
    }
    fn clockSensitive(runtime: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        _ = root_calls.fetchAdd(1, .monotonic);
        // The bare test context has no named global shape. os is installed in
        // the root environment's dynamic map, not an ABI numeric slot.
        const global = runtime.root_global_table orelse return error.MissingGlobalTable;
        const os = global.rawGet(.{ .string = "os" }) orelse return error.MissingOsLibrary;
        const clock = try runtime.getIndex(os, .{ .string = "clock" });
        const current = try runtime.callValue(clock, &.{});
        defer rt.freeResults(current);
        const table = try runtime.newTable();
        try table.rawSet(runtime.allocator, .{ .string = "value" }, current[0]);
        return one(.{ .table = table });
    }
    fn identitySensitive(runtime: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        _ = root_calls.fetchAdd(1, .monotonic);
        const to_string = runtime.getGlobal(global_abi.id("tostring"));
        if (to_string != .callable) return error.MissingToString;
        const object = try runtime.newTable();
        const address = try runtime.callValue(to_string, &.{.{ .table = object }});
        defer rt.freeResults(address);
        const table = try runtime.newTable();
        try table.rawSet(runtime.allocator, .{ .string = "value" }, address[0]);
        return one(.{ .table = table });
    }
    fn caughtFailure(runtime: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        _ = root_calls.fetchAdd(1, .monotonic);
        const pcall = runtime.getGlobal(global_abi.id("pcall"));
        if (pcall != .callable) return error.MissingPcall;
        const failing = try runtime.makeFunctionKnown(1, fail, &.{});
        const caught = try runtime.callValue(pcall, &.{failing});
        defer rt.freeResults(caught);
        const table = try runtime.newTable();
        try table.rawSet(runtime.allocator, .{ .string = "ok" }, caught[0]);
        return one(.{ .table = table });
    }
    fn fail(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        return error.NotCallable;
    }
    fn scalar(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        return one(.{ .string = "not a table" });
    }
    fn tableKey(runtime: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const key = try runtime.newTable();
        const table = try runtime.newTable();
        try table.rawSet(runtime.allocator, .{ .table = key }, .{ .boolean = true });
        return one(.{ .table = table });
    }
};

test "AOT loadData runs in an isolated context and promotes a cached read-only graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 4);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(DataProbe.root), rt.stabilize(DataProbe.fail), rt.stabilize(DataProbe.scalar), rt.stabilize(DataProbe.tableKey) };
    runtime.module_root_entries = &functions;
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
    runtime.clearAotErrorName();
    inline for (.{
        .{ "Module:DataScalar", "LoadDataTableExpected" },
        .{ "Module:DataTableKey", "LoadDataTableKey" },
    }) |case| {
        try std.testing.expectError(error.AotCallFailed, callField(&runtime, mw, "loadData", &.{.{ .string = case[0] }}));
        try std.testing.expectEqualStrings(case[1], runtime.aotErrorName().?);
        runtime.clearAotErrorName();
    }
    try std.testing.expect(first[0].table == second[0].table);
    try std.testing.expect(first[0].table.read_only);
    const marker = first[0].table.metatable orelse return error.MissingLoadDataMetatable;
    try std.testing.expect(marker.read_only);
    try std.testing.expect(marker.rawGet(.{ .string = "mw_loadData" }).?.boolean);
    try std.testing.expect(marker.rawGet(.{ .string = "__metatable" }).?.table == marker);
    const getmetatable_fn = runtime.getGlobal(7);
    const exposed = try runtime.callValue(getmetatable_fn, &.{first[0]});
    defer rt.freeResults(exposed);
    try std.testing.expect(exposed[0] == .table and exposed[0].table == marker);
    const setmetatable_fn = runtime.getGlobal(8);
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(setmetatable_fn, &.{ first[0], .{ .table = try runtime.newTable() } }));
    try std.testing.expectEqualStrings("ProtectedMetatable", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
    const nested = first[0].table.rawGet(.{ .string = "nested" }) orelse return error.MissingNestedData;
    try std.testing.expect(nested == .table and nested.table.read_only);
    try std.testing.expect(nested.table.metatable == marker);
    try std.testing.expectEqual(@as(f64, 7), nested.table.rawGet(.{ .string = "x" }).?.number);
    try std.testing.expectError(error.ReadOnlyTable, first[0].table.rawSet(runtime.allocator, .{ .string = "y" }, .{ .number = 1 }));
    try std.testing.expectEqual(@as(f64, 40), runtime.getGlobal(1).number);
}

test "AOT expander loadData cache survives fresh invoke contexts" {
    var page = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer page.deinit();
    var runtime = try rt.Context.initProgram(page.allocator(), 24, 4);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(DataProbe.root), rt.stabilize(DataProbe.fail), rt.stabilize(DataProbe.scalar), rt.stabilize(DataProbe.tableKey) };
    runtime.module_root_entries = &functions;
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
        try installForExpander(&shared_state, null, page.allocator(), &child, 0, 18, 23);
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
        try installForExpander(&shared_state, null, page.allocator(), &child, 0, 18, 23);
        const mw = child.getGlobal(23);
        const second = try callField(&child, mw, "loadData", &.{.{ .string = "Module:Data" }});
        defer rt.freeResults(second);
        try std.testing.expect(second[0] == .table);
        try std.testing.expect(second[0].table == first_table);
        try std.testing.expectEqual(@as(f64, 7), second[0].table.rawGet(.{ .string = "nested" }).?.table.rawGet(.{ .string = "x" }).?.number);
    }
}

test "shared loadData cache survives separate page allocators" {
    var runtime_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer runtime_arena.deinit();
    var runtime = try rt.Context.initProgram(runtime_arena.allocator(), 24, 4);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(DataProbe.root), rt.stabilize(DataProbe.fail), rt.stabilize(DataProbe.scalar), rt.stabilize(DataProbe.tableKey) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, DataProbe.lookup, DataProbe.name);

    var shared = SharedLoadDataCache.init(std.testing.allocator, &.{ true, true, true, true });
    defer shared.deinit();
    DataProbe.root_calls.store(0, .monotonic);
    var cached_table: ?*rt.Table = null;

    for (0..3) |page_index| {
        var page = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer page.deinit();
        var child = try runtime.forkProgram(page.allocator());
        defer child.deinit();
        try rt.bindGlobalTable(&child, null, 0);
        try stdlib.install(&child);
        var page_state: ?*anyopaque = null;
        try installForExpander(&page_state, &shared, page.allocator(), &child, 0, 18, 23);
        const mw = child.getGlobal(23);
        const loaded = try callField(&child, mw, "loadData", &.{.{ .string = "Module:Data" }});
        defer rt.freeResults(loaded);
        try std.testing.expect(loaded[0] == .table and loaded[0].table.read_only);
        if (page_index == 1) cached_table = loaded[0].table;
        if (page_index == 2) try std.testing.expect(loaded[0].table == cached_table.?);
    }
    try std.testing.expectEqual(@as(usize, 2), DataProbe.root_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), shared.entries.count());
    try std.testing.expect(shared.bytes != 0 and shared.bytes <= shared_load_data_max_bytes);
}

test "shared and page-local loadData results expose the same protected metatable" {
    const Names = struct {
        fn lookup(_: ?*const anyopaque, module_name: []const u8) ?u32 {
            if (std.mem.eql(u8, module_name, "Module:A")) return 0;
            if (std.mem.eql(u8, module_name, "Module:B")) return 1;
            return null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return switch (id) {
                0 => "Module:A",
                1 => "Module:B",
                else => null,
            };
        }
    };
    var runtime_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer runtime_arena.deinit();
    var runtime = try rt.Context.initProgram(runtime_arena.allocator(), 24, 2);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(DataProbe.root), rt.stabilize(DataProbe.root) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, Names.lookup, Names.name);
    var shared = SharedLoadDataCache.init(std.testing.allocator, &.{ false, false });
    defer shared.deinit();

    // Two successful evaluations promote A; B is first seen on the final page.
    for (0..3) |page_index| {
        var page = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer page.deinit();
        var child = try runtime.forkProgram(page.allocator());
        defer child.deinit();
        try rt.bindGlobalTable(&child, null, 0);
        try stdlib.install(&child);
        var page_state: ?*anyopaque = null;
        try installForExpander(&page_state, &shared, page.allocator(), &child, 0, 18, 23);
        const mw = child.getGlobal(23);
        const a = try callField(&child, mw, "loadData", &.{.{ .string = "Module:A" }});
        defer rt.freeResults(a);
        if (page_index != 2) continue;
        const b = try callField(&child, mw, "loadData", &.{.{ .string = "Module:B" }});
        defer rt.freeResults(b);
        try std.testing.expect(shared.entries.contains(0));
        try std.testing.expect(!shared.entries.contains(1));
        const getmetatable = child.getGlobal(global_abi.id("getmetatable"));
        const a_meta = try child.callValue(getmetatable, a);
        defer rt.freeResults(a_meta);
        const b_meta = try child.callValue(getmetatable, b);
        defer rt.freeResults(b_meta);
        try std.testing.expect(a_meta.len == 1 and a_meta[0] == .table);
        try std.testing.expect(b_meta.len == 1 and b_meta[0] == .table);
        try std.testing.expect(rt.rawEqual(a_meta[0], b_meta[0]));
        try std.testing.expect(a_meta[0].table.read_only);
        try std.testing.expectError(error.ReadOnlyTable, a[0].table.rawSet(child.allocator, .{ .string = "x" }, .nil));
        try std.testing.expectError(error.ReadOnlyTable, b[0].table.rawSet(child.allocator, .{ .string = "x" }, .nil));
    }
}

test "effect-free loadData root shares its read-only graph across pages" {
    var runtime_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer runtime_arena.deinit();
    var runtime = try rt.Context.initProgram(runtime_arena.allocator(), 24, 4);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(DataProbe.root), rt.stabilize(DataProbe.fail), rt.stabilize(DataProbe.scalar), rt.stabilize(DataProbe.tableKey) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, DataProbe.lookup, DataProbe.name);

    // This root has no compiler-proven static snapshot flag. The runtime
    // effect proof admits it only after executing in an isolated child.
    var shared = SharedLoadDataCache.init(std.testing.allocator, &.{ false, false, false, false });
    defer shared.deinit();
    DataProbe.root_calls.store(0, .monotonic);
    var promoted: ?*rt.Table = null;

    for (0..3) |page_index| {
        var page = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer page.deinit();
        var child = try runtime.forkProgram(page.allocator());
        defer child.deinit();
        try rt.bindGlobalTable(&child, null, 0);
        try stdlib.install(&child);
        var page_state: ?*anyopaque = null;
        try installForExpander(&page_state, &shared, page.allocator(), &child, 0, 18, 23);
        const loaded = try callField(&child, child.getGlobal(23), "loadData", &.{.{ .string = "Module:Data" }});
        defer rt.freeResults(loaded);
        const table = loaded[0].table;
        try std.testing.expect(table.read_only);
        const nested = table.rawGet(.{ .string = "nested" }).?.table;
        try std.testing.expect(nested == table.rawGet(.{ .string = "alias" }).?.table);
        try std.testing.expect(nested.read_only);
        if (page_index == 1) promoted = table;
        if (page_index == 2) try std.testing.expect(table == promoted.?);
    }
    try std.testing.expectEqual(@as(usize, 2), DataProbe.root_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), shared.entries.count());
}

test "shared loadData cache rejects oversized entries before destroying promotion arena" {
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    const a = source_arena.allocator();
    const source = try a.create(rt.Table);
    source.* = .{};
    const oversized = try a.alloc(u8, shared_load_data_max_entry_bytes + 4096);
    @memset(oversized, 'x');
    try source.rawSet(a, .{ .string = "payload" }, .{ .string = oversized });

    var shared = SharedLoadDataCache.init(std.testing.allocator, &.{true});
    defer shared.deinit();
    try std.testing.expect((try shared.tryPromote(0, .{ .table = source }, false)) == null);
    try std.testing.expect((try shared.tryPromote(0, .{ .table = source }, false)) == null);
    try std.testing.expectEqual(@as(usize, 0), shared.entries.count());
}

test "shared loadData cache skips page-sensitive modules" {
    var runtime_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer runtime_arena.deinit();
    var runtime = try rt.Context.initProgram(runtime_arena.allocator(), 24, 4);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(DataProbe.pageSensitive), rt.stabilize(DataProbe.fail), rt.stabilize(DataProbe.scalar), rt.stabilize(DataProbe.tableKey) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, DataProbe.lookup, DataProbe.name);

    var shared = SharedLoadDataCache.init(std.testing.allocator, &.{ false, true, true, true });
    defer shared.deinit();
    DataProbe.root_calls.store(0, .monotonic);
    var host = host_api.Host{};
    host_api.set(&runtime, &host);

    for (0..3) |page_index| {
        host.current_title = switch (page_index) {
            0 => "Alpha",
            1 => "Beta",
            else => "Gamma",
        };
        var page = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer page.deinit();
        var child = try runtime.forkProgram(page.allocator());
        defer child.deinit();
        try rt.bindGlobalTable(&child, null, 0);
        try stdlib.install(&child);
        var page_state: ?*anyopaque = null;
        try installForExpander(&page_state, &shared, page.allocator(), &child, 0, 18, 23);
        const mw = child.getGlobal(23);
        const loaded = try callField(&child, mw, "loadData", &.{.{ .string = "Module:Data" }});
        defer rt.freeResults(loaded);
        try std.testing.expect(loaded[0] == .table and loaded[0].table.read_only);
        try std.testing.expectEqualStrings(host.current_title, loaded[0].table.rawGet(.{ .string = "title" }).?.string);
    }
    try std.testing.expectEqual(@as(usize, 3), DataProbe.root_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), shared.entries.count());
    try std.testing.expect(shared.impure.contains(0));
}

test "shared loadData cache excludes clock, identity, and caught errors" {
    const probes = [_]rt.FunctionFn{
        rt.stabilize(DataProbe.clockSensitive),
        rt.stabilize(DataProbe.identitySensitive),
        rt.stabilize(DataProbe.caughtFailure),
    };
    for (probes) |probe| {
        var runtime_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer runtime_arena.deinit();
        var runtime = try rt.Context.initProgram(runtime_arena.allocator(), 24, 4);
        defer runtime.deinit();
        const functions = [_]rt.FunctionFn{ probe, rt.stabilize(DataProbe.fail), rt.stabilize(DataProbe.scalar), rt.stabilize(DataProbe.tableKey) };
        runtime.module_root_entries = &functions;
        runtime.configureModules(null, DataProbe.lookup, DataProbe.name);
        var shared = SharedLoadDataCache.init(std.testing.allocator, &.{ false, false, false, false });
        defer shared.deinit();
        DataProbe.root_calls.store(0, .monotonic);

        for (0..3) |_| {
            var page = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer page.deinit();
            var child = try runtime.forkProgram(page.allocator());
            defer child.deinit();
            try rt.bindGlobalTable(&child, null, 0);
            try stdlib.install(&child);
            var page_state: ?*anyopaque = null;
            try installForExpander(&page_state, &shared, page.allocator(), &child, 0, 18, 23);
            const loaded = try callField(&child, child.getGlobal(23), "loadData", &.{.{ .string = "Module:Data" }});
            defer rt.freeResults(loaded);
            try std.testing.expect(loaded[0] == .table);
        }
        try std.testing.expectEqual(@as(usize, 3), DataProbe.root_calls.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 0), shared.entries.count());
        try std.testing.expect(shared.impure.contains(0));
    }
}

test "nested loadData keeps the outer result page-local" {
    const Probe = struct {
        var outer_calls = std.atomic.Value(usize).init(0);
        var inner_calls = std.atomic.Value(usize).init(0);
        fn lookup(_: ?*const anyopaque, module_name: []const u8) ?u32 {
            if (std.mem.eql(u8, module_name, "Module:Outer")) return 0;
            if (std.mem.eql(u8, module_name, "Module:Inner")) return 1;
            return null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return switch (id) {
                0 => "Module:Outer",
                1 => "Module:Inner",
                else => null,
            };
        }
        fn inner(runtime: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            _ = inner_calls.fetchAdd(1, .monotonic);
            const table = try runtime.newTable();
            try table.rawSet(runtime.allocator, .{ .string = "x" }, .{ .number = 7 });
            return one(.{ .table = table });
        }
        fn outer(runtime: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            _ = outer_calls.fetchAdd(1, .monotonic);
            const nested = try callField(runtime, runtime.getGlobal(23), "loadData", &.{.{ .string = "Module:Inner" }});
            defer rt.freeResults(nested);
            const table = try runtime.newTable();
            try table.rawSet(runtime.allocator, .{ .string = "x" }, nested[0].table.rawGet(.{ .string = "x" }).?);
            return one(.{ .table = table });
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 2);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(Probe.outer), rt.stabilize(Probe.inner) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, Probe.lookup, Probe.name);
    var shared = SharedLoadDataCache.init(std.testing.allocator, &.{ false, false });
    defer shared.deinit();
    Probe.outer_calls.store(0, .monotonic);
    Probe.inner_calls.store(0, .monotonic);
    for (0..3) |_| {
        var page = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer page.deinit();
        var child = try runtime.forkProgram(page.allocator());
        defer child.deinit();
        try rt.bindGlobalTable(&child, null, 0);
        try stdlib.install(&child);
        var page_state: ?*anyopaque = null;
        try installForExpander(&page_state, &shared, page.allocator(), &child, 0, 18, 23);
        const loaded = try callField(&child, child.getGlobal(23), "loadData", &.{.{ .string = "Module:Outer" }});
        defer rt.freeResults(loaded);
        try std.testing.expectEqual(@as(f64, 7), loaded[0].table.rawGet(.{ .string = "x" }).?.number);
    }
    try std.testing.expectEqual(@as(usize, 3), Probe.outer_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), Probe.inner_calls.load(.monotonic));
    try std.testing.expect(shared.impure.contains(0));
    try std.testing.expect(shared.entries.contains(1));
    try std.testing.expect(!shared.entries.contains(0));
}

const JsonDataProbe = struct {
    fn model(_: ?*anyopaque, title: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, title, "Module:Data.json") or
            std.mem.eql(u8, title, "Module:Scalar.json") or
            std.mem.eql(u8, title, "Module:Broken.json")) return "json";
        if (std.mem.eql(u8, title, "Module:Wrong.json")) return "Scribunto";
        return null;
    }

    fn content(_: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?[]const u8 {
        const source = if (std.mem.eql(u8, title, "Module:Data.json"))
            "{\"cuts\":[1,2],\"nested\":{\"ok\":true}}"
        else if (std.mem.eql(u8, title, "Module:Scalar.json"))
            "7"
        else if (std.mem.eql(u8, title, "Module:Broken.json"))
            "{bad"
        else if (std.mem.eql(u8, title, "Module:Wrong.json"))
            "{}"
        else
            return null;
        return try a.dupe(u8, source);
    }
};

test "AOT loadJsonData reads corpus JSON once and returns a cached read-only graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try makeMovedHostContext(arena.allocator());
    defer runtime.deinit();
    var host = Host{ .page_content = JsonDataProbe.content, .page_content_model = JsonDataProbe.model };
    setHost(&runtime, &host);
    const mw = runtime.getGlobal(23);

    const first = try callField(&runtime, mw, "loadJsonData", &.{.{ .string = "Module:Data.json" }});
    defer rt.freeResults(first);
    const second = try callField(&runtime, mw, "loadJsonData", &.{.{ .string = "Module:Data.json" }});
    defer rt.freeResults(second);
    try std.testing.expect(first[0] == .table and first[0].table == second[0].table);
    try std.testing.expect(first[0].table.read_only);
    const cuts = first[0].table.rawGet(.{ .string = "cuts" }).?.table;
    try std.testing.expect(cuts.read_only);
    try std.testing.expectEqual(@as(f64, 2), cuts.rawGet(.{ .number = 2 }).?.number);
    const nested = first[0].table.rawGet(.{ .string = "nested" }).?.table;
    try std.testing.expect(nested.read_only and nested.rawGet(.{ .string = "ok" }).?.boolean);
    try std.testing.expectError(error.ReadOnlyTable, cuts.rawSet(runtime.allocator, .{ .number = 1 }, .{ .number = 9 }));

    const load_json = try runtime.getIndex(mw, .{ .string = "loadJsonData" });
    inline for (.{
        .{ "Module:Missing.json", "InvalidJsonPage" },
        .{ "Module:Wrong.json", "InvalidJsonPage" },
        .{ "Module:Broken.json", "InvalidJsonPage" },
        .{ "Module:Scalar.json", "LoadJsonDataTableExpected" },
    }) |case| {
        try std.testing.expectError(error.AotCallFailed, runtime.callValue(load_json, &.{.{ .string = case[0] }}));
        try std.testing.expectEqualStrings(case[1], runtime.aotErrorName().?);
        runtime.clearAotErrorName();
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
    try source.rawSet(runtime.allocator, .{ .table = source }, .{ .string = "source-key" });
    const mw = runtime.getGlobal(2);
    const cloned = try callField(&runtime, mw, "clone", &.{.{ .table = source }});
    defer rt.freeResults(cloned);
    try std.testing.expect(cloned[0] == .table and cloned[0].table != source);
    try std.testing.expect(cloned[0].table.rawGet(.{ .string = "self" }).?.table == cloned[0].table);
    try std.testing.expectEqualStrings("source-key", cloned[0].table.rawGet(.{ .table = source }).?.string);
    try std.testing.expect(cloned[0].table.rawGet(.{ .table = cloned[0].table }) == null);
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
    const os_value = try runtime.getIndex(runtime.getGlobal(0), .{ .string = "os" });
    try std.testing.expect(os_value == .table and os_value.table.rawGet(.{ .string = "date" }).? == .callable);
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

test "AOT mw.text trim listToText truncate encode tag killMarkers and nowiki match Scribunto behavior" {
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

    const suffix = try callField(&runtime, text, "truncate", &.{ .{ .string = "abcdef" }, .{ .number = -2 }, .{ .string = "" } });
    defer rt.freeResults(suffix);
    try std.testing.expectEqualStrings("ef", suffix[0].string);
    const default_ellipsis = try callField(&runtime, text, "truncate", &.{ .{ .string = "abcdef" }, .{ .number = 2 } });
    defer rt.freeResults(default_ellipsis);
    try std.testing.expectEqualStrings("ab...", default_ellipsis[0].string);
    const adjusted = try callField(&runtime, text, "truncate", &.{ .{ .string = "abcdef" }, .{ .number = 4 }, .{ .string = "..." }, .{ .boolean = true } });
    defer rt.freeResults(adjusted);
    try std.testing.expectEqualStrings("a...", adjusted[0].string);
    const no_growth = try callField(&runtime, text, "truncate", &.{ .{ .string = "abc" }, .{ .number = 1 } });
    defer rt.freeResults(no_growth);
    try std.testing.expectEqualStrings("abc", no_growth[0].string);
    const decoded = try callField(&runtime, text, "decode", &.{.{ .string = "&gt;&lt;&amp;&quot;&#039;&nbsp; &#65; &#x1F4A1; &copy; &amp;quot;" }});
    defer rt.freeResults(decoded);
    try std.testing.expectEqualStrings("><&\"'\u{a0} A 💡 &copy; &quot;", decoded[0].string);
    const decoded_named = try callField(&runtime, text, "decode", &.{ .{ .string = "&copy; &NotGreaterFullEqual; &emdash; &amp;copy;" }, .{ .boolean = true } });
    defer rt.freeResults(decoded_named);
    try std.testing.expectEqualStrings("© \u{2267}\u{338} &emdash; &copy;", decoded_named[0].string);
    const unicode = try callField(&runtime, text, "truncate", &.{ .{ .string = "é猫xyz" }, .{ .number = 2 }, .{ .string = "" } });
    defer rt.freeResults(unicode);
    try std.testing.expectEqualStrings("é猫", unicode[0].string);

    const encoded = try callField(&runtime, text, "encode", &.{.{ .string = "><&\"'\u{a0}" }});
    defer rt.freeResults(encoded);
    try std.testing.expectEqualStrings("&gt;&lt;&amp;&quot;&#039;&nbsp;", encoded[0].string);
    const attrs = try runtime.newTable();
    try attrs.rawSet(runtime.allocator, .{ .string = "style" }, .{ .string = "a&b" });
    const tagged = try callField(&runtime, text, "tag", &.{ .{ .string = "div" }, .{ .table = attrs }, .{ .string = "body" } });
    defer rt.freeResults(tagged);
    try std.testing.expectEqualStrings("<div style=\"a&amp;b\">body</div>", tagged[0].string);
    const opening = try callField(&runtime, text, "tag", &.{ .{ .string = "div" }, .{ .table = attrs } });
    defer rt.freeResults(opening);
    try std.testing.expectEqualStrings("<div style=\"a&amp;b\">", opening[0].string);
    const self_closed = try callField(&runtime, text, "tag", &.{ .{ .string = "br" }, .nil, .{ .boolean = false } });
    defer rt.freeResults(self_closed);
    try std.testing.expectEqualStrings("<br />", self_closed[0].string);
    const killed = try callField(&runtime, text, "killMarkers", &.{.{ .string = "a\x7f'\"`UNIQ--nowiki-00000000-QINU`\"'\x7fb" }});
    defer rt.freeResults(killed);
    try std.testing.expectEqualStrings("ab", killed[0].string);
    const malformed_marker = try callField(&runtime, text, "killMarkers", &.{.{ .string = "a\x7f'\"`UNIQ---QINU`\"'\x7fb" }});
    defer rt.freeResults(malformed_marker);
    try std.testing.expectEqualStrings("a\x7f'\"`UNIQ---QINU`\"'\x7fb", malformed_marker[0].string);

    inline for (.{
        .{ "[[x|y]]", "&#91;&#91;x&#124;y&#93;&#93;" },
        .{ "# item\n* two", "&#35; item\n&#42; two" },
        .{ "----\n__TOC__", "&#45;---\n_&#95;TOC_&#95;" },
        .{ "http://x ISBN 1", "http&#58;//x ISBN&#32;1" },
        .{ "mailto:x@y", "mailto&#58;x@y" },
        .{ "matrix:room wikipedia://Foo", "matrix&#58;room wikipedia&#58;//Foo" },
        .{ "wikipedia:Foo MATRIX:room WiKiPeDiA:Bar", "wikipedia&#58;Foo MATRIX&#58;room WiKiPeDiA&#58;Bar" },
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

test "AOT mw.text JSON preserves Scribunto array and flag semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try makeMovedHostContext(arena.allocator());
    defer runtime.deinit();
    const text = try runtime.getIndex(runtime.getGlobal(23), .{ .string = "text" });
    try std.testing.expectEqual(@as(f64, 1), (try runtime.getIndex(text, .{ .string = "JSON_PRESERVE_KEYS" })).number);
    try std.testing.expectEqual(@as(f64, 2), (try runtime.getIndex(text, .{ .string = "JSON_TRY_FIXING" })).number);
    try std.testing.expectEqual(@as(f64, 4), (try runtime.getIndex(text, .{ .string = "JSON_PRETTY" })).number);

    const decoded = try callField(&runtime, text, "jsonDecode", &.{ .{ .string = "{\"x\":[1,2],\"ok\":true}" }, .{ .number = 2 } });
    defer rt.freeResults(decoded);
    const x = decoded[0].table.rawGet(.{ .string = "x" }).?.table;
    try std.testing.expectEqual(@as(f64, 1), x.rawGet(.{ .number = 1 }).?.number);
    try std.testing.expectEqual(@as(f64, 2), x.rawGet(.{ .number = 2 }).?.number);
    try std.testing.expect(decoded[0].table.rawGet(.{ .string = "ok" }).?.boolean);

    const numeric_keys = try callField(&runtime, text, "jsonDecode", &.{.{ .string = "{\"x\":\"x\",\"1\":1,\"2\":2,\"01\":3}" }});
    defer rt.freeResults(numeric_keys);
    try std.testing.expectEqual(@as(f64, 1), numeric_keys[0].table.rawGet(.{ .number = 1 }).?.number);
    try std.testing.expectEqual(@as(f64, 2), numeric_keys[0].table.rawGet(.{ .number = 2 }).?.number);
    try std.testing.expectEqualStrings("x", numeric_keys[0].table.rawGet(.{ .string = "x" }).?.string);
    try std.testing.expectEqual(@as(f64, 3), numeric_keys[0].table.rawGet(.{ .string = "01" }).?.number);
    try std.testing.expect(numeric_keys[0].table.rawGet(.{ .string = "1" }) == null);
    const large_numeric_key = try callField(&runtime, text, "jsonDecode", &.{.{ .string = "{\"1000\":1}" }});
    defer rt.freeResults(large_numeric_key);
    try std.testing.expectEqual(@as(f64, 1), large_numeric_key[0].table.rawGet(.{ .number = 1000 }).?.number);

    const encoded = try callField(&runtime, text, "jsonEncode", &.{decoded[0]});
    defer rt.freeResults(encoded);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), encoded[0].string, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("x").?.array.items[1].integer);
    try std.testing.expect(parsed.value.object.get("ok").?.bool);

    const sequence = try runtime.newTable();
    try sequence.rawSet(runtime.allocator, .{ .number = 1 }, .{ .number = 10 });
    try sequence.rawSet(runtime.allocator, .{ .number = 2 }, .{ .number = 20 });
    const compact = try callField(&runtime, text, "jsonEncode", &.{.{ .table = sequence }});
    defer rt.freeResults(compact);
    try std.testing.expectEqualStrings("[10,20]", compact[0].string);
    const pretty = try callField(&runtime, text, "jsonEncode", &.{ .{ .table = sequence }, .{ .number = 4 } });
    defer rt.freeResults(pretty);
    try std.testing.expectEqualStrings("[\n    10,\n    20\n]", pretty[0].string);

    const preserved = try callField(&runtime, text, "jsonDecode", &.{ .{ .string = "[10,20]" }, .{ .number = 1 } });
    defer rt.freeResults(preserved);
    try std.testing.expectEqual(@as(f64, 10), preserved[0].table.rawGet(.{ .number = 0 }).?.number);
    try std.testing.expectEqual(@as(f64, 20), preserved[0].table.rawGet(.{ .number = 1 }).?.number);
    const preserved_encoded = try callField(&runtime, text, "jsonEncode", &.{ preserved[0], .{ .number = 1 } });
    defer rt.freeResults(preserved_encoded);
    try std.testing.expectEqualStrings("[10,20]", preserved_encoded[0].string);

    const fixed = try callField(&runtime, text, "jsonDecode", &.{ .{ .string = "[1,]" }, .{ .number = 2 } });
    defer rt.freeResults(fixed);
    try std.testing.expectEqual(@as(f64, 1), fixed[0].table.rawGet(.{ .number = 1 }).?.number);
    const decode_fn = try runtime.getIndex(text, .{ .string = "jsonDecode" });
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(decode_fn, &.{ .{ .string = "[[1,],[2,],[3,]]" }, .{ .number = 2 } }));
    try std.testing.expectEqualStrings("InvalidJson", runtime.aotErrorName().?);
    runtime.clearAotErrorName();

    try sequence.rawSet(runtime.allocator, .{ .string = "self" }, .{ .table = sequence });
    const encode_fn = try runtime.getIndex(text, .{ .string = "jsonEncode" });
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(encode_fn, &.{.{ .table = sequence }}));
    try std.testing.expectEqualStrings("JsonRecursiveTable", runtime.aotErrorName().?);
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
        .{ "hash", "hash" },
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

pub const WikitextProvider = @import("wikitext.zig").Provider;
pub const WikitextExpander = @import("wikitext.zig").Expander;
pub fn makeWikitextExpander(runtime: *rt.Context, env_slot: u32, string_slot: u32, mw_slot: u32, provider: WikitextProvider) WikitextExpander {
    return makeWikitextExpanderShared(runtime, env_slot, string_slot, mw_slot, provider, null);
}

pub fn makeWikitextExpanderShared(
    runtime: *rt.Context,
    env_slot: u32,
    string_slot: u32,
    mw_slot: u32,
    provider: WikitextProvider,
    shared: ?*SharedLoadDataCache,
) WikitextExpander {
    return .{
        .runtime = runtime,
        .env_slot = env_slot,
        .string_slot = string_slot,
        .mw_slot = mw_slot,
        .provider = provider,
        .install_scribunto = installForExpander,
        .scribunto_shared = shared,
    };
}

test "AOT loadData uses eager private snapshot without exposing mutable module value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
    defer runtime.deinit();
    runtime.configureModules(null, DataProbe.lookup, DataProbe.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);

    const source = try runtime.newTable();
    try source.rawSet(runtime.allocator, .{ .string = "x" }, .{ .number = 7 });
    try runtime.preinitializeModule(0, .{ .table = source }, true);
    try std.testing.expect(runtime.package_loaded.?.rawGet(.{ .string = "Module:Data" }) == null);
    try source.rawSet(runtime.allocator, .{ .string = "x" }, .{ .number = 99 });

    try install(&runtime, 0, 18, 23);
    const mw = runtime.getGlobal(23);
    const loaded = try callField(&runtime, mw, "loadData", &.{.{ .string = "Module:Data" }});
    defer rt.freeResults(loaded);
    try std.testing.expect(loaded[0] == .table and loaded[0].table.read_only);
    try std.testing.expectEqual(@as(f64, 7), loaded[0].table.rawGet(.{ .string = "x" }).?.number);
    try std.testing.expect(runtime.package_loaded.?.rawGet(.{ .string = "Module:Data" }) == null);
}
