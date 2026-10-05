const std = @import("std");
const rt = @import("zig_runtime");
const namespace_lib = @import("namespaces.zig");
const host_api = @import("host.zig");
const text_lib = @import("text.zig");
const wikibase_lib = @import("wikibase.zig");
const Value = rt.Value;

fn one(value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

fn noOpCall(_: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    return &.{};
}

fn addWarningCall(_: ?*anyopaque, _: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    return &.{};
}

fn falseCall(_: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    return one(.{ .boolean = false });
}

fn notImplementedCall(_: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    return error.NotImplemented;
}

fn statsIndexCall(_: ?*anyopaque, _: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 2 or args[1] != .string) return one(.nil);
    inline for (.{ "pages", "articles", "files", "edits", "users", "activeUsers", "admins" }) |name|
        if (std.mem.eql(u8, args[1].string, name)) return error.NotImplemented;
    return one(.nil);
}

fn categoryDbKey(runtime: *rt.Context, raw: []const u8) ![]const u8 {
    const without_fragment = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
    const trimmed = std.mem.trim(u8, without_fragment, " _");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(runtime.allocator);
    var pending_separator = false;
    for (trimmed) |c| {
        if (c == ' ' or c == '_') {
            pending_separator = out.items.len != 0;
            continue;
        }
        if (pending_separator) try out.append(runtime.allocator, '_');
        pending_separator = false;
        try out.append(runtime.allocator, c);
    }
    return out.toOwnedSlice(runtime.allocator);
}

fn pagesInCategoryCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const which = if (args.len < 2 or args[1] == .nil)
        "all"
    else if (args[1] != .string)
        return error.StringExpected
    else
        args[1].string;

    rt.work_stats.noteCategory(args[0].string, which);
    const host = host_api.getForStablePageRead(runtime) orelse return error.NotImplemented;
    const get = host.category_stats orelse return error.NotImplemented;
    const key = try categoryDbKey(runtime, args[0].string);
    const stats = (try get(host.ctx, key)) orelse host_api.CategoryStats{ .all = 0, .subcats = 0, .files = 0 };

    if (std.mem.eql(u8, which, "*")) {
        const result = try runtime.newTable();
        try result.rawSet(runtime.allocator, .{ .string = "all" }, .{ .number = @floatFromInt(stats.all) });
        try result.rawSet(runtime.allocator, .{ .string = "pages" }, .{ .number = @floatFromInt(stats.pages()) });
        try result.rawSet(runtime.allocator, .{ .string = "subcats" }, .{ .number = @floatFromInt(stats.subcats) });
        try result.rawSet(runtime.allocator, .{ .string = "files" }, .{ .number = @floatFromInt(stats.files) });
        return one(.{ .table = result });
    }
    if (std.mem.eql(u8, which, "all")) return one(.{ .number = @floatFromInt(stats.all) });
    if (std.mem.eql(u8, which, "pages")) return one(.{ .number = @floatFromInt(stats.pages()) });
    if (std.mem.eql(u8, which, "subcats")) return one(.{ .number = @floatFromInt(stats.subcats) });
    if (std.mem.eql(u8, which, "files")) return one(.{ .number = @floatFromInt(stats.files) });
    return error.InvalidCategoryCountKind;
}

const DumpState = struct {
    runtime: *rt.Context,
    table_labels: std.AutoHashMapUnmanaged(*rt.Table, []const u8) = .empty,
    expanded_tables: std.AutoHashMapUnmanaged(*rt.Table, void) = .empty,
    function_labels: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    table_count: u32 = 0,
    function_count: u32 = 0,

    fn deinit(self: *DumpState) void {
        self.table_labels.deinit(self.runtime.allocator);
        self.expanded_tables.deinit(self.runtime.allocator);
        self.function_labels.deinit(self.runtime.allocator);
    }

    fn appendIndent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, count: usize) !void {
        for (0..count) |_| try out.appendSlice(allocator, "  ");
    }

    fn appendQuoted(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
        try out.append(allocator, '"');
        for (text) |c| switch (c) {
            '"', '\\' => {
                try out.append(allocator, '\\');
                try out.append(allocator, c);
            },
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            0 => try out.appendSlice(allocator, "\\000"),
            else => if (c < 32 or c == 127) {
                var buf: [4]u8 = undefined;
                try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "\\{d:0>3}", .{c}));
            } else try out.append(allocator, c),
        };
        try out.append(allocator, '"');
    }

    fn functionLabel(self: *DumpState, identity: u32) ![]const u8 {
        if (self.function_labels.get(identity)) |label| return label;
        self.function_count += 1;
        const label = try std.fmt.allocPrint(self.runtime.allocator, "function#{d}", .{self.function_count});
        try self.function_labels.put(self.runtime.allocator, identity, label);
        return label;
    }

    fn tableLabel(self: *DumpState, table: *rt.Table) ![]const u8 {
        if (self.table_labels.get(table)) |label| return label;
        if (table.metatable) |mt| if (mt.rawGet(.{ .string = "__tostring" })) |method| {
            const result = try self.runtime.callValue(method, &.{.{ .table = table }});
            defer rt.freeResults(result);
            if (result.len == 0 or result[0] != .string) return error.StringExpected;
            if (!std.mem.eql(u8, result[0].string, "table")) {
                const label = try self.runtime.allocator.dupe(u8, result[0].string);
                try self.table_labels.put(self.runtime.allocator, table, label);
                try self.expanded_tables.put(self.runtime.allocator, table, {});
                return label;
            }
        };
        self.table_count += 1;
        const label = try std.fmt.allocPrint(self.runtime.allocator, "table#{d}", .{self.table_count});
        try self.table_labels.put(self.runtime.allocator, table, label);
        return label;
    }

    fn containsKey(keys: []const Value, key: Value) bool {
        for (keys) |seen| if (rt.rawEqual(seen, key)) return true;
        return false;
    }

    fn keyRank(value: Value) u8 {
        return switch (value) {
            .boolean => 0,
            .callable => 1,
            .nil => 2,
            .number => 3,
            .string => 4,
            .table => 5,
        };
    }

    fn keyLess(a: Value, b: Value) bool {
        const ar = keyRank(a);
        const br = keyRank(b);
        if (ar != br) return ar < br;
        return switch (a) {
            .boolean => !a.boolean and b.boolean,
            .number => a.number < b.number,
            .string => std.mem.order(u8, a.string, b.string) == .lt,
            else => false,
        };
    }

    fn sortKeys(keys: []Value) void {
        var i: usize = 1;
        while (i < keys.len) : (i += 1) {
            const key = keys[i];
            var j = i;
            while (j > 0 and keyLess(key, keys[j - 1])) : (j -= 1) keys[j] = keys[j - 1];
            keys[j] = key;
        }
    }

    fn dumpIpairs(self: *DumpState, table: *rt.Table, out: *std.ArrayList(u8), indent: usize, done_keys: *std.ArrayList(Value)) !void {
        const allocator = self.runtime.allocator;
        const object = Value{ .table = table };
        if (table.metatable) |mt| if (mt.rawGet(.{ .string = "__ipairs" })) |method| {
            const triple = try self.runtime.callValue(method, &.{object});
            defer rt.freeResults(triple);
            const iter = if (triple.len > 0) triple[0] else Value.nil;
            const state = if (triple.len > 1) triple[1] else Value.nil;
            var key = if (triple.len > 2) triple[2] else Value.nil;
            while (true) {
                const result = try self.runtime.callValue(iter, &.{ state, key });
                defer rt.freeResults(result);
                if (result.len == 0 or result[0] == .nil) break;
                key = result[0];
                const value = if (result.len > 1) result[1] else Value.nil;
                try done_keys.append(allocator, key);
                try appendIndent(out, allocator, indent + 2);
                try self.dumpValue(out, value, indent + 2, true);
                try out.appendSlice(allocator, ",\n");
            }
            return;
        };
        var index: usize = 1;
        while (table.rawGetNumber(@floatFromInt(index))) |value| : (index += 1) {
            try done_keys.append(allocator, .{ .number = @floatFromInt(index) });
            try appendIndent(out, allocator, indent + 2);
            try self.dumpValue(out, value, indent + 2, true);
            try out.appendSlice(allocator, ",\n");
        }
    }

    fn collectPairKeys(self: *DumpState, table: *rt.Table, done_keys: []const Value, keys: *std.ArrayList(Value)) !void {
        const allocator = self.runtime.allocator;
        const object = Value{ .table = table };
        if (table.metatable) |mt| if (mt.rawGet(.{ .string = "__pairs" })) |method| {
            const triple = try self.runtime.callValue(method, &.{object});
            defer rt.freeResults(triple);
            const iter = if (triple.len > 0) triple[0] else Value.nil;
            const state = if (triple.len > 1) triple[1] else Value.nil;
            var key = if (triple.len > 2) triple[2] else Value.nil;
            while (true) {
                const result = try self.runtime.callValue(iter, &.{ state, key });
                defer rt.freeResults(result);
                if (result.len == 0 or result[0] == .nil) break;
                key = result[0];
                if (!containsKey(done_keys, key)) try keys.append(allocator, key);
            }
            return;
        };
        var iterator = table.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!containsKey(done_keys, key)) try keys.append(allocator, key);
        }
    }

    fn dumpTable(self: *DumpState, out: *std.ArrayList(u8), table: *rt.Table, indent: usize, expand_table: bool) anyerror!void {
        const allocator = self.runtime.allocator;
        const label = try self.tableLabel(table);
        try out.appendSlice(allocator, label);
        if (self.expanded_tables.contains(table) or !expand_table) return;
        try self.expanded_tables.put(allocator, table, {});
        try out.appendSlice(allocator, " {\n");

        if (table.metatable) |mt| {
            const visible = mt.rawGet(.{ .string = "__metatable" }) orelse Value{ .table = mt };
            try appendIndent(out, allocator, indent + 2);
            try out.appendSlice(allocator, "metatable = ");
            try self.dumpValue(out, visible, indent + 2, false);
            try out.append(allocator, '\n');
        }

        var done_keys: std.ArrayList(Value) = .empty;
        defer done_keys.deinit(allocator);
        try self.dumpIpairs(table, out, indent, &done_keys);

        var keys: std.ArrayList(Value) = .empty;
        defer keys.deinit(allocator);
        try self.collectPairKeys(table, done_keys.items, &keys);
        sortKeys(keys.items);
        for (keys.items) |key| {
            try appendIndent(out, allocator, indent + 2);
            try out.append(allocator, '[');
            try self.dumpValue(out, key, indent + 3, false);
            try out.appendSlice(allocator, "] = ");
            try self.dumpValue(out, try self.runtime.getIndex(.{ .table = table }, key), indent + 2, true);
            try out.appendSlice(allocator, ",\n");
        }
        try appendIndent(out, allocator, indent);
        try out.append(allocator, '}');
    }

    fn dumpValue(self: *DumpState, out: *std.ArrayList(u8), value: Value, indent: usize, expand_table: bool) anyerror!void {
        const allocator = self.runtime.allocator;
        switch (value) {
            .nil => try out.appendSlice(allocator, "nil"),
            .boolean => |v| try out.appendSlice(allocator, if (v) "true" else "false"),
            .number => |v| try out.appendSlice(allocator, try rt.numberToString(allocator, v)),
            .string => |v| try appendQuoted(out, allocator, v),
            .table => |v| try self.dumpTable(out, v, indent, expand_table),
            .callable => |v| try out.appendSlice(allocator, try self.functionLabel(v.identity)),
        }
    }
};

fn dumpObjectCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    // Labels and iteration of object graphs can depend on identity and
    // allocation order, which differ between isolated page evaluations.
    if (args.len != 0 and (args[0] == .table or args[0] == .callable)) rt.markLoadDataEffect();
    var state = DumpState{ .runtime = runtime };
    defer state.deinit();
    var out: std.ArrayList(u8) = .empty;
    try state.dumpValue(&out, if (args.len == 0) .nil else args[0], 0, true);
    return one(.{ .string = try out.toOwnedSlice(runtime.allocator) });
}

const MessageCtx = struct {
    key: ?[]const u8 = null,
    raw_message: ?[]const u8 = null,
    language: ?[]const u8 = null,
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

fn snapshotMessageSource(runtime: *rt.Context, host: *host_api.Host, language: []const u8, key: []const u8) !?[]const u8 {
    const normalized = try host_api.normalizeInterfaceMessageKeyAlloc(runtime.allocator, key);
    defer runtime.allocator.free(normalized);
    const get = host.interface_message orelse {
        std.log.warn("interface message snapshot unavailable: language={s} key={s}", .{ language[0..@min(language.len, 128)], normalized[0..@min(normalized.len, 256)] });
        return error.InterfaceMessageSnapshotMissing;
    };
    const resolved = (try get(host.ctx, runtime.allocator, language, normalized)) orelse {
        std.log.warn("interface message missing: language={s} key={s}", .{ language[0..@min(language.len, 128)], normalized[0..@min(normalized.len, 256)] });
        return error.InterfaceMessageSnapshotMissing;
    };
    // Scribunto plain() substitutes $N but preserves template/parser syntax.
    return resolved.source;
}

fn messageSource(runtime: *rt.Context, ctx: *const MessageCtx) !?[]const u8 {
    if (ctx.raw_message) |source| {
        if (ctx.language != null) return error.NotImplemented;
        return source;
    }
    const key = ctx.key orelse return error.MissingMessageKey;
    const host = host_api.getForStablePageRead(runtime) orelse {
        const normalized = try host_api.normalizeInterfaceMessageKeyAlloc(runtime.allocator, key);
        defer runtime.allocator.free(normalized);
        const language = ctx.language orelse if (runtime.namespace_catalog) |catalog| catalog.content_language else "<unavailable>";
        std.log.warn("interface message host unavailable: language={s} key={s}", .{ language[0..@min(language.len, 128)], normalized[0..@min(normalized.len, 256)] });
        return error.InterfaceMessageSnapshotMissing;
    };
    if (ctx.language) |language|
        return snapshotMessageSource(runtime, host, language, key);

    if (host.page_content) |get| {
        if (try get(host.ctx, runtime.allocator, try messageTitleAlloc(runtime.allocator, key))) |source|
            return source;
    }
    const catalog = runtime.namespace_catalog orelse return error.NamespaceRegistryRequired;
    return snapshotMessageSource(runtime, host, catalog.content_language, key);
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

fn checkedMessageParam(runtime: *rt.Context, value: Value) !Value {
    return if (value == .table)
        Value{ .string = try messageParamString(runtime, value) }
    else switch (value) {
        .string, .number => value,
        else => return error.MessageParamExpected,
    };
}

fn appendMessageParams(runtime: *rt.Context, ctx: *MessageCtx, values: []const Value) !void {
    // Scribunto accepts either one sequence table or individual parameters.
    // An object with __tostring remains a scalar parameter in either form.
    if (values.len != 0 and values[0] == .table and
        (if (runtime.metamethod(values[0], "__tostring")) |method| !method.truthy() else true))
    {
        if (values.len != 1) return error.MixedMessageParameterForms;
        const params = values[0];
        // Match table.maxn, not the sequence length: holes are invalid params.
        var maximum: f64 = 0;
        var entries = params.table.iterator();
        while (entries.next()) |entry| {
            if (entry.key_ptr.* == .number and entry.key_ptr.number > maximum)
                maximum = entry.key_ptr.number;
        }
        var index: f64 = 1;
        while (index <= maximum) : (index += 1) {
            const key = Value{ .number = index };
            const stored = try checkedMessageParam(runtime, try runtime.getIndex(params, key));
            // checkParams writes scalarized objects back into the caller's array.
            try runtime.setIndex(params, key, stored);
            try ctx.params.append(runtime.allocator, stored);
        }
        return;
    }
    for (values) |value|
        try ctx.params.append(runtime.allocator, try checkedMessageParam(runtime, value));
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

fn messageInLanguageCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx: *MessageCtx = @ptrCast(@alignCast(raw orelse return error.MissingMessageContext));
    if (args.len < 2 or args[1] != .string) return error.NotImplemented;
    ctx.language = try runtime.allocator.dupe(u8, args[1].string);
    return one(args[0]);
}

fn makeMessageObject(runtime: *rt.Context, ctx: *MessageCtx) ![]const Value {
    const object = try runtime.newNativeNamespace(.message_value);
    const plain = try runtime.newNative(ctx, messagePlainCall);
    try object.rawSet(runtime.allocator, .{ .string = "plain" }, plain);
    try object.rawSet(runtime.allocator, .{ .string = "exists" }, try runtime.newNative(ctx, messageExistsCall));
    try object.rawSet(runtime.allocator, .{ .string = "isBlank" }, try runtime.newNative(ctx, messageIsBlankCall));
    try object.rawSet(runtime.allocator, .{ .string = "isDisabled" }, try runtime.newNative(ctx, messageIsDisabledCall));
    try object.rawSet(runtime.allocator, .{ .string = "inLanguage" }, try runtime.newNative(ctx, messageInLanguageCall));
    inline for (.{ "params", "rawParams", "numParams", "useDatabase" }) |name|
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

fn tableField(table: *rt.Table, name: []const u8) ?Value {
    return table.rawGet(.{ .string = name });
}

// JsonConfig selects from ordered JSON before conversion to Lua hash tables.
fn localizedJsonString(host: *host_api.Host, language: []const u8, value: std.json.Value) !std.json.Value {
    if (value != .object) return error.InvalidExternalDataSnapshot;
    if (value.object.get(language)) |selected| {
        if (selected != .string) return error.InvalidExternalDataSnapshot;
        return selected;
    }
    if (!std.mem.eql(u8, language, "en")) {
        const get = host.language_fallbacks orelse {
            std.log.warn("language fallback snapshot unavailable: language={s}", .{language[0..@min(language.len, 128)]});
            return error.LanguageFallbackSnapshotMissing;
        };
        for (try get(host.ctx, language)) |fallback| {
            if (value.object.get(fallback)) |selected| {
                if (selected != .string) return error.InvalidExternalDataSnapshot;
                return selected;
            }
        }
    }
    // The snapshot stores STRICT. MESSAGES appends English, and JsonConfig
    // also explicitly checks English after that chain.
    if (value.object.get("en")) |selected| {
        if (selected != .string) return error.InvalidExternalDataSnapshot;
        return selected;
    }
    if (value.object.count() == 0) return .{ .string = "" };
    const first = value.object.values()[0];
    if (first != .string) return error.InvalidExternalDataSnapshot;
    // PHP reset($map) ?: '' also treats the string "0" as false.
    return if (std.mem.eql(u8, first.string, "0")) .{ .string = "" } else first;
}

fn localizedJsonLicense(runtime: *rt.Context, a: std.mem.Allocator, host: *host_api.Host, language: []const u8, code: []const u8) !std.json.Value {
    var license: std.json.ObjectMap = .empty;
    try license.put(a, "code", .{ .string = code });
    inline for (.{ .{ "text", "name" }, .{ "url", "url" } }) |field| {
        const key = try std.fmt.allocPrint(runtime.allocator, "jsonconfig-license-{s}-{s}", .{ field[1], code });
        defer runtime.allocator.free(key);
        const resolved = (try snapshotMessageSource(runtime, host, language, key)) orelse
            try std.fmt.allocPrint(runtime.allocator, "⧼{s}⧽", .{key});
        try license.put(a, field[0], .{ .string = resolved });
    }
    return .{ .object = license };
}

fn localizedTabularJson(runtime: *rt.Context, a: std.mem.Allocator, host: *host_api.Host, language: []const u8, raw: std.json.Value) !std.json.Value {
    if (raw != .object) return error.InvalidExternalDataSnapshot;
    var out: std.json.ObjectMap = .empty;
    if (raw.object.get("description")) |description|
        try out.put(a, "description", try localizedJsonString(host, language, description));
    if (raw.object.get("license")) |license| {
        if (license != .string) return error.InvalidExternalDataSnapshot;
        try out.put(a, "license", try localizedJsonLicense(runtime, a, host, language, license.string));
    }
    inline for (.{ "sources", "mediawikiCategories" }) |key|
        if (raw.object.get(key)) |value| try out.put(a, key, value);

    const schema = raw.object.get("schema") orelse return error.InvalidExternalDataSnapshot;
    if (schema != .object) return error.InvalidExternalDataSnapshot;
    const fields = schema.object.get("fields") orelse return error.InvalidExternalDataSnapshot;
    if (fields != .array) return error.InvalidExternalDataSnapshot;
    var localized_columns: std.ArrayList(bool) = .empty;
    var out_fields: std.array_list.Managed(std.json.Value) = .init(a);
    for (fields.array.items) |field| {
        if (field != .object) return error.InvalidExternalDataSnapshot;
        const name = field.object.get("name") orelse return error.InvalidExternalDataSnapshot;
        const kind = field.object.get("type") orelse return error.InvalidExternalDataSnapshot;
        if (name != .string or kind != .string) return error.InvalidExternalDataSnapshot;
        var out_field: std.json.ObjectMap = .empty;
        try out_field.put(a, "name", name);
        try out_field.put(a, "type", kind);
        try out_field.put(a, "title", if (field.object.get("title")) |title| try localizedJsonString(host, language, title) else name);
        try out_fields.append(.{ .object = out_field });
        try localized_columns.append(a, std.mem.eql(u8, kind.string, "localized"));
    }
    var out_schema: std.json.ObjectMap = .empty;
    try out_schema.put(a, "fields", .{ .array = out_fields });
    try out.put(a, "schema", .{ .object = out_schema });
    const data = raw.object.get("data") orelse std.json.Value{ .array = .init(a) };
    if (data != .array) return error.InvalidExternalDataSnapshot;
    for (data.array.items) |row| {
        if (row != .array or row.array.items.len != localized_columns.items.len) return error.InvalidExternalDataSnapshot;
        for (row.array.items, localized_columns.items) |*cell, localized| {
            if (localized and cell.* != .null)
                cell.* = try localizedJsonString(host, language, cell.*);
        }
    }
    try out.put(a, "data", data);
    return .{ .object = out };
}

fn reindexPreservedArray(runtime: *rt.Context, source: *rt.Table) !*rt.Table {
    const len = source.append_index;
    if (len == std.math.maxInt(u32)) return error.InvalidExternalDataSnapshot;
    const out = try runtime.newArrayTable(len);
    var index: u32 = 0;
    while (index < len) : (index += 1) {
        if (source.rawGetNumber(@floatFromInt(index))) |value|
            try out.rawSet(runtime.allocator, .{ .number = @floatFromInt(index + 1) }, value);
    }
    out.append_index = len + 1;
    return out;
}

fn reindexTabularRaw(runtime: *rt.Context, raw: *rt.Table) !void {
    const schema_value = tableField(raw, "schema") orelse return error.InvalidExternalDataSnapshot;
    if (schema_value != .table) return error.InvalidExternalDataSnapshot;
    const fields_value = tableField(schema_value.table, "fields") orelse return error.InvalidExternalDataSnapshot;
    if (fields_value != .table) return error.InvalidExternalDataSnapshot;
    const fields = try reindexPreservedArray(runtime, fields_value.table);
    try schema_value.table.rawSet(runtime.allocator, .{ .string = "fields" }, .{ .table = fields });

    const data_value = tableField(raw, "data") orelse return error.InvalidExternalDataSnapshot;
    if (data_value != .table) return error.InvalidExternalDataSnapshot;
    const row_count = data_value.table.append_index;
    if (row_count == std.math.maxInt(u32)) return error.InvalidExternalDataSnapshot;
    const data = try runtime.newArrayTable(row_count);
    var row_index: u32 = 0;
    while (row_index < row_count) : (row_index += 1) {
        const row_value = data_value.table.rawGetNumber(@floatFromInt(row_index)) orelse continue;
        if (row_value != .table) return error.InvalidExternalDataSnapshot;
        const row = try reindexPreservedArray(runtime, row_value.table);
        try data.rawSet(runtime.allocator, .{ .number = @floatFromInt(row_index + 1) }, .{ .table = row });
    }
    data.append_index = row_count + 1;
    try raw.rawSet(runtime.allocator, .{ .string = "data" }, .{ .table = data });
}

fn externalDataGetCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const language = if (args.len < 2 or args[1] == .nil)
        (runtime.namespace_catalog orelse return error.NamespaceRegistryRequired).content_language
    else if (args[1] == .string)
        args[1].string
    else
        return error.StringExpected;
    rt.work_stats.noteCommons(args[0].string, language);
    const raw = std.mem.eql(u8, language, "_");
    if (!std.mem.endsWith(u8, args[0].string, ".tab")) return error.NotImplemented;
    const host = host_api.getForStablePageRead(runtime) orelse return error.NotImplemented;
    const get = host.external_data orelse return error.NotImplemented;
    const entry = (try get(host.ctx, args[0].string)) orelse return one(.{ .boolean = false });
    if (!std.mem.eql(u8, entry.content_model, "Tabular.JsonConfig")) return error.NotImplemented;
    var parsed = std.json.parseFromSlice(std.json.Value, runtime.allocator, entry.source, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidExternalDataSnapshot;
    };
    defer parsed.deinit();
    const selected = if (raw) parsed.value else try localizedTabularJson(runtime, parsed.arena.allocator(), host, language, parsed.value);
    const decoded = text_lib.jsonToLua(runtime, selected, true) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidExternalDataSnapshot;
    };
    if (decoded != .table) return error.InvalidExternalDataSnapshot;
    try reindexTabularRaw(runtime, decoded.table);
    return one(decoded);
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
    const host = host_api.getForStableInterwikiMap(runtime) orelse return error.MissingScribuntoHost;
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
        try entry.rawSet(runtime.allocator, .{ .string = "isTranscludable" }, .{ .boolean = row.is_transcludable });
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

const wikibase_site_global_id = "enwiktionary";
const wikibase_entity_url_prefix = "https://www.wikidata.org/wiki/Special:EntityPage/";

fn canonicalWikibaseEntityId(runtime: *rt.Context, raw: []const u8) !?[]const u8 {
    return wikibase_lib.canonicalEntityId(runtime, raw);
}

fn wikibaseGetGlobalSiteIdCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return wikibase_lib.getGlobalSiteIdCall(raw, runtime, args);
}

fn wikibaseIsValidEntityIdCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    return one(.{ .boolean = (try canonicalWikibaseEntityId(runtime, args[0].string)) != null });
}

fn wikibaseGetEntityUrlCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const id = (try canonicalWikibaseEntityId(runtime, args[0].string)) orelse return one(.nil);
    const url = try std.fmt.allocPrint(runtime.allocator, "{s}{s}", .{ wikibase_entity_url_prefix, id });
    return one(.{ .string = url });
}

fn wikibaseGetSitelinkCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (host_api.getForStablePageRead(runtime)) |host| {
        if (host.wikibase_entity != null) return wikibase_lib.getSitelinkCall(null, runtime, args);
    }
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const global_site_id = if (args.len < 2 or args[1] == .nil)
        (runtime.namespace_catalog orelse return error.MissingNamespaceRegistry).wiki
    else if (args[1] == .string)
        args[1].string
    else
        return error.StringExpected;
    rt.work_stats.noteSitelink(args[0].string, global_site_id);
    const host = host_api.getForStablePageRead(runtime) orelse return error.MissingScribuntoHost;
    const get = host.wikibase_sitelink orelse return error.NotImplemented;
    const title = get(host.ctx, args[0].string, global_site_id) catch |err| {
        if (err == error.WikibaseSitelinkSnapshotMissing) {
            runtime.last_error = .{ .string = try std.fmt.allocPrint(
                runtime.allocator,
                "Wikibase sitelink snapshot missing entity={s} site={s}",
                .{ args[0].string, global_site_id },
            ) };
            return error.LuaRaised;
        }
        return err;
    };
    return one(if (title) |value| .{ .string = value } else .nil);
}

fn wikibaseEntityText(runtime: *rt.Context, args: []const Value) !?host_api.WikibaseEntityText {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const entity_id = (try canonicalWikibaseEntityId(runtime, args[0].string)) orelse return null;
    const host = host_api.getForStablePageRead(runtime) orelse return error.MissingScribuntoHost;
    const get = host.wikibase_entity_text orelse return error.NotImplemented;
    return get(host.ctx, entity_id) catch |err| {
        if (err == error.WikibaseEntityTextSnapshotMissing) {
            runtime.last_error = .{ .string = try std.fmt.allocPrint(
                runtime.allocator,
                "Wikibase entity-text snapshot missing entity={s}",
                .{entity_id},
            ) };
            return error.LuaRaised;
        }
        return err;
    };
}

fn wikibaseGetLabelCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (host_api.getForStablePageRead(runtime)) |host| {
        if (host.wikibase_entity != null) return wikibase_lib.getLabelCall(null, runtime, args);
    }
    const entity = (try wikibaseEntityText(runtime, args)) orelse return one(.nil);
    return one(if (entity.label) |label| .{ .string = label } else .nil);
}

fn wikibaseGetDescriptionCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (host_api.getForStablePageRead(runtime)) |host| {
        if (host.wikibase_entity != null) return wikibase_lib.getDescriptionCall(null, runtime, args);
    }
    const entity = (try wikibaseEntityText(runtime, args)) orelse return one(.nil);
    return one(if (entity.description) |description| .{ .string = description } else .nil);
}

pub fn install(runtime: *rt.Context, mw: *rt.Table) !void {
    try setMwNative(runtime, mw, "dumpObject", dumpObjectCall);
    try setMwNative(runtime, mw, "log", noOpCall);
    try setMwNative(runtime, mw, "logObject", noOpCall);
    try setMwNative(runtime, mw, "addWarning", addWarningCall);
    try setMwNative(runtime, mw, "incrementExpensiveFunctionCount", noOpCall);
    try setMwNative(runtime, mw, "isSubsting", falseCall);

    const site = try runtime.newNativeNamespace(.site);
    const namespaces = try namespace_lib.makeTable(runtime);
    try site.rawSet(runtime.allocator, .{ .string = "namespaces" }, .{ .table = namespaces });
    // Scribunto's filtered maps retain numeric IDs and the original objects.
    // Only the complete namespace map supports lookup by name and alias.
    inline for (.{
        .{ "subjectNamespaces", "isSubject" },
        .{ "talkNamespaces", "isTalk" },
        .{ "contentNamespaces", "isContent" },
    }) |selection| {
        const filtered = try runtime.newNativeNamespace(.namespace_map);
        var entries = namespaces.iterator();
        while (entries.next()) |entry| {
            const value = entry.value_ptr.*;
            if (value.table.rawGet(.{ .string = selection[1] }).?.boolean)
                try filtered.rawSet(runtime.allocator, entry.key_ptr.*, value);
        }
        try site.rawSet(runtime.allocator, .{ .string = selection[0] }, .{ .table = filtered });
    }
    const stats = try runtime.newNativeNamespace(.site_stats);
    try setNative(runtime, stats, "pagesInCategory", pagesInCategoryCall);
    inline for (.{ "pagesInNamespace", "usersInGroup" }) |name|
        try setNative(runtime, stats, name, notImplementedCall);
    const stats_mt = try runtime.newTable();
    try stats_mt.rawSet(runtime.allocator, .{ .string = "__index" }, try runtime.newNative(null, statsIndexCall));
    stats.metatable = stats_mt;
    try site.rawSet(runtime.allocator, .{ .string = "stats" }, .{ .table = stats });
    try setNative(runtime, site, "interwikiMap", interwikiMapCall);
    try mw.rawSetNativeField(.mw, "site", .{ .table = site });

    const ext = try runtime.newNativeNamespace(.ext);
    const ext_data = try runtime.newNativeNamespace(.ext_data);
    try setNative(runtime, ext_data, "get", externalDataGetCall);
    try ext.rawSet(runtime.allocator, .{ .string = "data" }, .{ .table = ext_data });
    try mw.rawSetNativeField(.mw, "ext", .{ .table = ext });

    const wikibase = try runtime.newNativeNamespace(.wikibase);
    inline for (.{
        "getEntityIdForTitle",
        "getEntityIdForCurrentPage",
        "formatValue",
        "entityExists",
    }) |name| try setNative(runtime, wikibase, name, notImplementedCall);
    try setNative(runtime, wikibase, "getEntity", wikibase_lib.getEntityCall);
    try setNative(runtime, wikibase, "getAllStatements", wikibase_lib.getAllStatementsCall);
    try setNative(runtime, wikibase, "getBestStatements", wikibase_lib.getBestStatementsCall);
    try setNative(runtime, wikibase, "getLabelWithLang", wikibase_lib.getLabelWithLangCall);
    try setNative(runtime, wikibase, "getLabelByLang", wikibase_lib.getLabelByLangCall);
    try setNative(runtime, wikibase, "getDescription", wikibaseGetDescriptionCall);
    try setNative(runtime, wikibase, "getLabel", wikibaseGetLabelCall);
    try setNative(runtime, wikibase, "getSitelink", wikibaseGetSitelinkCall);
    try setNative(runtime, wikibase, "sitelink", wikibaseGetSitelinkCall);
    try setNative(runtime, wikibase, "getEntityUrl", wikibaseGetEntityUrlCall);
    try setNative(runtime, wikibase, "getGlobalSiteId", wikibaseGetGlobalSiteIdCall);
    try setNative(runtime, wikibase, "isValidEntityId", wikibaseIsValidEntityIdCall);
    try mw.rawSetNativeField(.mw, "wikibase", .{ .table = wikibase });

    const message = try runtime.newNativeNamespace(.message);
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
    const quoted = try callField(&runtime, .{ .table = mw }, "dumpObject", &.{.{ .string = "line\n\"quoted\"" }});
    defer rt.freeResults(quoted);
    try std.testing.expectEqualStrings("\"line\\n\\\"quoted\\\"\"", quoted[0].string);

    const nested = try runtime.newTable();
    try nested.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "y" });
    const object = try runtime.newTable();
    try object.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "x" });
    try object.rawSet(runtime.allocator, .{ .boolean = false }, .{ .string = "bool" });
    try object.rawSet(runtime.allocator, .{ .string = "a" }, .{ .boolean = true });
    try object.rawSet(runtime.allocator, .{ .string = "nested" }, .{ .table = nested });
    try object.rawSet(runtime.allocator, .{ .string = "self" }, .{ .table = object });
    const table_dump = try callField(&runtime, .{ .table = mw }, "dumpObject", &.{.{ .table = object }});
    defer rt.freeResults(table_dump);
    try std.testing.expectEqualStrings(
        \\table#1 {
        \\    "x",
        \\    [false] = "bool",
        \\    ["a"] = true,
        \\    ["nested"] = table#2 {
        \\        "y",
        \\    },
        \\    ["self"] = table#1,
        \\}
    , table_dump[0].string);

    const protected = try runtime.newTable();
    const protected_mt = try runtime.newTable();
    try protected_mt.rawSet(runtime.allocator, .{ .string = "__metatable" }, .{ .string = "hidden" });
    protected.metatable = protected_mt;
    const protected_dump = try callField(&runtime, .{ .table = mw }, "dumpObject", &.{.{ .table = protected }});
    defer rt.freeResults(protected_dump);
    try std.testing.expectEqualStrings(
        \\table#1 {
        \\    metatable = "hidden"
        \\}
    , protected_dump[0].string);

    const logged = try callField(&runtime, .{ .table = mw }, "log", &.{.{ .string = "ignored" }});
    defer rt.freeResults(logged);
    try std.testing.expectEqual(@as(usize, 0), logged.len);
    const warning = try callField(&runtime, .{ .table = mw }, "addWarning", &.{.{ .string = "ignored" }});
    defer rt.freeResults(warning);
    try std.testing.expectEqual(@as(usize, 0), warning.len);
    try std.testing.expectError(error.AotCallFailed, callField(&runtime, .{ .table = mw }, "addWarning", &.{.{ .boolean = true }}));
    try std.testing.expectEqualStrings("StringExpected", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
    const expensive = try callField(&runtime, .{ .table = mw }, "incrementExpensiveFunctionCount", &.{});
    defer rt.freeResults(expensive);
    try std.testing.expectEqual(@as(usize, 0), expensive.len);
    const substing = try callField(&runtime, .{ .table = mw }, "isSubsting", &.{});
    defer rt.freeResults(substing);
    try std.testing.expect(!substing[0].boolean);

    const ext = mw.rawGet(.{ .string = "ext" }).?.table;
    const ext_data = ext.rawGet(.{ .string = "data" }).?.table;
    try std.testing.expect(ext_data.rawGet(.{ .string = "get" }).? == .callable);
    try std.testing.expectError(error.AotCallFailed, callField(&runtime, .{ .table = ext_data }, "get", &.{.{ .string = "Unicode/data" }}));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();

    const wikibase = mw.rawGet(.{ .string = "wikibase" }).?.table;
    inline for (.{
        "getEntity",
        "getEntityIdForTitle",
        "getDescription",
        "getLabel",
        "getEntityIdForCurrentPage",
        "getSitelink",
        "getEntityUrl",
        "getBestStatements",
        "getLabelWithLang",
        "getLabelByLang",
        "getAllStatements",
        "getGlobalSiteId",
        "formatValue",
        "isValidEntityId",
        "entityExists",
        "sitelink",
    }) |name| try std.testing.expect(wikibase.rawGet(.{ .string = name }).? == .callable);
    try std.testing.expectError(error.AotCallFailed, callField(&runtime, .{ .table = wikibase }, "formatValue", &.{.{ .string = "Q1" }}));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();

    const global_site = try callField(&runtime, .{ .table = wikibase }, "getGlobalSiteId", &.{});
    defer rt.freeResults(global_site);
    try std.testing.expectEqualStrings("enwiktionary", global_site[0].string);

    inline for (.{ "Q1", "q1", "P31", "p31", "L1", "l1", "L1-F1", "L1-S1" }) |id| {
        const valid = try callField(&runtime, .{ .table = wikibase }, "isValidEntityId", &.{.{ .string = id }});
        defer rt.freeResults(valid);
        try std.testing.expect(valid[0].boolean);
    }
    inline for (.{ "M1", "Q0", "Q01", "Q2147483648", "l1-f1", "l1-s1", "Property:P31", "" }) |id| {
        const invalid = try callField(&runtime, .{ .table = wikibase }, "isValidEntityId", &.{.{ .string = id }});
        defer rt.freeResults(invalid);
        try std.testing.expect(!invalid[0].boolean);
    }

    const entity_url = try callField(&runtime, .{ .table = wikibase }, "getEntityUrl", &.{.{ .string = "q1" }});
    defer rt.freeResults(entity_url);
    try std.testing.expectEqualStrings("https://www.wikidata.org/wiki/Special:EntityPage/Q1", entity_url[0].string);
    const form_url = try callField(&runtime, .{ .table = wikibase }, "getEntityUrl", &.{.{ .string = "L1-F1" }});
    defer rt.freeResults(form_url);
    try std.testing.expectEqualStrings("https://www.wikidata.org/wiki/Special:EntityPage/L1-F1", form_url[0].string);
    const bad_url = try callField(&runtime, .{ .table = wikibase }, "getEntityUrl", &.{.{ .string = "Q0" }});
    defer rt.freeResults(bad_url);
    try std.testing.expect(bad_url[0] == .nil);

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
    const template_by_name = try runtime.getIndex(.{ .table = namespaces }, .{ .string = "Template" });
    try std.testing.expect(template_by_name == .table and template_by_name.table == template);
    const project = namespaces.rawGet(.{ .number = 4 }).?.table;
    try std.testing.expectEqualStrings("Project", project.rawGet(.{ .string = "canonicalName" }).?.string);
    const aliases = project.rawGet(.{ .string = "aliases" }).?.table;
    try std.testing.expectEqualStrings("WT", aliases.rawGet(.{ .number = 1 }).?.string);
    const subjects = site.rawGet(.{ .string = "subjectNamespaces" }).?.table;
    const talks = site.rawGet(.{ .string = "talkNamespaces" }).?.table;
    const contents = site.rawGet(.{ .string = "contentNamespaces" }).?.table;
    try std.testing.expect(subjects.rawGet(.{ .number = 0 }).?.table == namespaces.rawGet(.{ .number = 0 }).?.table);
    try std.testing.expect(subjects.rawGet(.{ .number = -1 }).?.table == namespaces.rawGet(.{ .number = -1 }).?.table);
    try std.testing.expect(subjects.rawGet(.{ .number = 1 }) == null);
    try std.testing.expect(talks.rawGet(.{ .number = 1 }).?.table == namespaces.rawGet(.{ .number = 1 }).?.table);
    try std.testing.expect(talks.rawGet(.{ .number = 0 }) == null);
    try std.testing.expect(talks.rawGet(.{ .number = -1 }) == null);
    try std.testing.expect(contents.rawGet(.{ .number = 0 }).?.table == namespaces.rawGet(.{ .number = 0 }).?.table);
    try std.testing.expect((try runtime.getIndex(.{ .table = subjects }, .{ .string = "Template" })) == .nil);
    inline for (.{
        .{ "subjectNamespaces", "isSubject" },
        .{ "talkNamespaces", "isTalk" },
        .{ "contentNamespaces", "isContent" },
    }) |selection| {
        const filtered = site.rawGet(.{ .string = selection[0] }).?.table;
        var expected_count: usize = 0;
        var all_entries = namespaces.iterator();
        while (all_entries.next()) |entry| {
            if (entry.value_ptr.*.table.rawGet(.{ .string = selection[1] }).?.boolean)
                expected_count += 1;
        }
        var actual_count: usize = 0;
        var filtered_entries = filtered.iterator();
        while (filtered_entries.next()) |entry| {
            try std.testing.expect(entry.key_ptr.* == .number);
            try std.testing.expect(entry.value_ptr.*.table == namespaces.rawGet(entry.key_ptr.*).?.table);
            actual_count += 1;
        }
        try std.testing.expectEqual(expected_count, actual_count);
    }
    try subjects.rawGet(.{ .number = 10 }).?.table.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = "shared namespace" });
    try std.testing.expectEqualStrings("shared namespace", template.rawGet(.{ .string = "name" }).?.string);
    const stats = site.rawGet(.{ .string = "stats" }).?.table;
    inline for (.{ "pagesInCategory", "pagesInNamespace", "usersInGroup" }) |name|
        try std.testing.expect(stats.rawGet(.{ .string = name }).? == .callable);
    try std.testing.expectError(error.AotCallFailed, callField(&runtime, .{ .table = stats }, "pagesInCategory", &.{ .{ .string = "English nouns" }, .{ .string = "pages" } }));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
    try std.testing.expectError(error.AotCallFailed, runtime.getIndex(.{ .table = stats }, .{ .string = "pages" }));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
}

const ExternalDataProbe = struct {
    const source =
        \\{"license":"CC-BY-SA-4.0","description":{"en":"Example","fr":"Exemple"},"sources":"source","mediawikiCategories":[{"name":"Data"}],"schema":{"fields":[{"name":"key","type":"string","title":{"en":"Key"}},{"name":"label","type":"localized","title":{"en":"Label"}}]},"data":[["0x41",{"en":"A","fr":"Une"}]]}
    ;

    fn get(_: ?*anyopaque, title: []const u8) !?host_api.ExternalData {
        if (std.mem.eql(u8, title, "Example.tab"))
            return .{ .content_model = "Tabular.JsonConfig", .source = source };
        if (std.mem.eql(u8, title, "Other.map"))
            return .{ .content_model = "Map.JsonConfig", .source = "{}" };
        return null;
    }

    fn message(_: ?*anyopaque, _: std.mem.Allocator, language: []const u8, key: []const u8) !?host_api.InterfaceMessage {
        if (!std.mem.eql(u8, language, "en")) return error.InterfaceMessageSnapshotMissing;
        if (std.mem.eql(u8, key, "jsonconfig-license-name-CC-BY-SA-4.0"))
            return .{ .source = "Creative Commons Attribution-Share Alike 4.0" };
        if (std.mem.eql(u8, key, "jsonconfig-license-url-CC-BY-SA-4.0"))
            return .{ .source = "https://creativecommons.org/licenses/by-sa/4.0/deed.en" };
        return error.InterfaceMessageSnapshotMissing;
    }
};

test "AOT mw ext data reads explicit tabular snapshot exactly and fails closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .external_data = ExternalDataProbe.get, .interface_message = ExternalDataProbe.message };
    host_api.set(&runtime, &host);
    const mw = try runtime.newNativeNamespace(.mw);
    try install(&runtime, mw);
    const ext_data = mw.rawGet(.{ .string = "ext" }).?.table.rawGet(.{ .string = "data" }).?.table;

    const first = try callField(&runtime, .{ .table = ext_data }, "get", &.{.{ .string = "Example.tab" }});
    defer rt.freeResults(first);
    const second = try callField(&runtime, .{ .table = ext_data }, "get", &.{.{ .string = "Example.tab" }});
    defer rt.freeResults(second);
    try std.testing.expect(first[0] == .table and second[0] == .table and first[0].table != second[0].table);
    try std.testing.expectEqualStrings("Example", first[0].table.rawGet(.{ .string = "description" }).?.string);
    const license = first[0].table.rawGet(.{ .string = "license" }).?.table;
    try std.testing.expectEqualStrings("CC-BY-SA-4.0", license.rawGet(.{ .string = "code" }).?.string);
    try std.testing.expectEqualStrings("Creative Commons Attribution-Share Alike 4.0", license.rawGet(.{ .string = "text" }).?.string);
    const fields = first[0].table.rawGet(.{ .string = "schema" }).?.table.rawGet(.{ .string = "fields" }).?.table;
    try std.testing.expect(fields.rawGetNumber(0) == null);
    try std.testing.expectEqualStrings("Key", fields.rawGetNumber(1).?.table.rawGet(.{ .string = "title" }).?.string);
    const data = first[0].table.rawGet(.{ .string = "data" }).?.table;
    try std.testing.expect(data.rawGetNumber(0) == null);
    try std.testing.expectEqualStrings("A", data.rawGetNumber(1).?.table.rawGetNumber(2).?.string);
    const categories = first[0].table.rawGet(.{ .string = "mediawikiCategories" }).?.table;
    try std.testing.expectEqualStrings("Data", categories.rawGetNumber(0).?.table.rawGet(.{ .string = "name" }).?.string);
    try std.testing.expect(categories.rawGetNumber(1) == null);

    try first[0].table.rawSet(runtime.allocator, .{ .string = "probe" }, .{ .boolean = true });
    try std.testing.expect(second[0].table.rawGet(.{ .string = "probe" }) == null);

    const raw = try callField(&runtime, .{ .table = ext_data }, "get", &.{ .{ .string = "Example.tab" }, .{ .string = "_" } });
    defer rt.freeResults(raw);
    try std.testing.expect(raw[0].table.rawGet(.{ .string = "description" }).? == .table);
    try std.testing.expectEqualStrings("CC-BY-SA-4.0", raw[0].table.rawGet(.{ .string = "license" }).?.string);
    const raw_categories = raw[0].table.rawGet(.{ .string = "mediawikiCategories" }).?.table;
    try std.testing.expectEqualStrings("Data", raw_categories.rawGetNumber(0).?.table.rawGet(.{ .string = "name" }).?.string);
    try std.testing.expect(raw_categories.rawGetNumber(1) == null);
    const raw_label = raw[0].table.rawGet(.{ .string = "data" }).?.table.rawGetNumber(1).?.table.rawGetNumber(2).?.table;
    try std.testing.expectEqualStrings("Une", raw_label.rawGet(.{ .string = "fr" }).?.string);

    const missing = try callField(&runtime, .{ .table = ext_data }, "get", &.{.{ .string = "Missing.tab" }});
    defer rt.freeResults(missing);
    try std.testing.expect(missing[0] == .boolean and !missing[0].boolean);
    try std.testing.expectError(error.AotCallFailed, callField(&runtime, .{ .table = ext_data }, "get", &.{ .{ .string = "Example.tab" }, .{ .string = "fr" } }));
    try std.testing.expectEqualStrings("InterfaceMessageSnapshotMissing", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
    try std.testing.expectError(error.AotCallFailed, callField(&runtime, .{ .table = ext_data }, "get", &.{.{ .string = "Other.map" }}));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
}

const CategoryStatsProbe = struct {
    fn get(_: ?*anyopaque, key: []const u8) !?host_api.CategoryStats {
        if (std.mem.eql(u8, key, "English_lemmas"))
            return .{ .all = 878_433, .subcats = 16, .files = 0 };
        return null;
    }
};

test "AOT mw site pagesInCategory reads pinned category statistics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .category_stats = CategoryStatsProbe.get };
    host_api.set(&runtime, &host);
    const mw = try runtime.newNativeNamespace(.mw);
    try install(&runtime, mw);
    const stats = mw.rawGet(.{ .string = "site" }).?.table.rawGet(.{ .string = "stats" }).?.table;

    inline for (.{
        .{ "English lemmas", "all", 878_433 },
        .{ "English__lemmas", "pages", 878_417 },
        .{ " _English_lemmas_#fragment", "subcats", 16 },
        .{ "English lemmas", "files", 0 },
        .{ "english lemmas", "all", 0 },
        .{ "English\tlemmas", "all", 0 },
    }) |probe| {
        const result = try callField(&runtime, .{ .table = stats }, "pagesInCategory", &.{ .{ .string = probe[0] }, .{ .string = probe[1] } });
        defer rt.freeResults(result);
        try std.testing.expect(result[0] == .number);
        try std.testing.expectEqual(@as(f64, probe[2]), result[0].number);
    }

    const all_counts = try callField(&runtime, .{ .table = stats }, "pagesInCategory", &.{ .{ .string = "English lemmas" }, .{ .string = "*" } });
    defer rt.freeResults(all_counts);
    try std.testing.expect(all_counts[0] == .table);
    try std.testing.expectEqual(@as(f64, 878_433), all_counts[0].table.rawGet(.{ .string = "all" }).?.number);
    try std.testing.expectEqual(@as(f64, 878_417), all_counts[0].table.rawGet(.{ .string = "pages" }).?.number);
    try std.testing.expectEqual(@as(f64, 16), all_counts[0].table.rawGet(.{ .string = "subcats" }).?.number);
    try std.testing.expectEqual(@as(f64, 0), all_counts[0].table.rawGet(.{ .string = "files" }).?.number);

    const default_count = try callField(&runtime, .{ .table = stats }, "pagesInCategory", &.{.{ .string = "English lemmas" }});
    defer rt.freeResults(default_count);
    try std.testing.expectEqual(@as(f64, 878_433), default_count[0].number);

    try std.testing.expectError(error.AotCallFailed, callField(&runtime, .{ .table = stats }, "pagesInCategory", &.{ .{ .string = "English lemmas" }, .{ .string = "bogus" } }));
    try std.testing.expectEqualStrings("InvalidCategoryCountKind", runtime.aotErrorName().?);
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

    fn interfaceMessage(_: ?*anyopaque, _: std.mem.Allocator, language: []const u8, key: []const u8) !?host_api.InterfaceMessage {
        if (std.mem.eql(u8, language, "en") and std.mem.eql(u8, key, "missing_key"))
            return .{ .source = null };
        if (std.mem.eql(u8, language, "en") and std.mem.eql(u8, key, "word-separator"))
            return .{ .source = " " };
        if (std.mem.eql(u8, language, "fr") and std.mem.eql(u8, key, "parentheses"))
            return .{ .source = "[$1]" };
        if (std.mem.eql(u8, language, "fr") and std.mem.eql(u8, key, "known-missing"))
            return .{ .source = null };
        if (std.mem.eql(u8, language, "fr") and std.mem.eql(u8, key, "magic"))
            return .{ .source = "{{PLURAL:$1|one|many}}" };
        return null;
    }
};

test "AOT mw message reads dump-backed interface messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    var host = host_api.Host{ .page_content = MessageProbe.pageContent, .interface_message = MessageProbe.interfaceMessage };
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

test "message constructors accept one parameter array and preserve scalar tostring objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const a = runtime.allocator;
    const Scalar = struct {
        fn render(_: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
            return one(.{ .string = "object" });
        }
    };
    const object = try runtime.newTable();
    const mt = try runtime.newTable();
    try mt.rawSet(a, .{ .string = "__tostring" }, try runtime.newNative(null, Scalar.render));
    object.metatable = mt;
    const false_mt = try runtime.newTable();
    try false_mt.rawSet(a, .{ .string = "__tostring" }, .{ .boolean = false });
    const params = try runtime.newTable();
    params.metatable = false_mt;
    try params.rawSet(a, .{ .number = 1 }, .{ .string = "word" });
    try params.rawSet(a, .{ .number = 2 }, .{ .number = 17 });
    try params.rawSet(a, .{ .number = 3 }, .{ .table = object });
    try params.rawSet(a, .{ .number = 3.5 }, .{ .boolean = false });
    try params.rawSet(a, .{ .number = -1 }, .{ .boolean = false });
    try params.rawSet(a, .{ .string = "ignored" }, .{ .boolean = false });
    const message = try messageNewRawCall(null, &runtime, &.{ .{ .string = "$1/$2/$3" }, .{ .table = params } });
    defer rt.freeResults(message);
    const plain = try callField(&runtime, message[0], "plain", &.{message[0]});
    defer rt.freeResults(plain);
    try std.testing.expectEqualStrings("word/17/object", plain[0].string);
    try std.testing.expectEqualStrings("object", params.rawGetNumber(3).?.string);

    const scalar = try messageNewRawCall(null, &runtime, &.{ .{ .string = "$1:$2" }, .{ .table = object }, .{ .string = "tail" } });
    defer rt.freeResults(scalar);
    const scalar_plain = try callField(&runtime, scalar[0], "plain", &.{scalar[0]});
    defer rt.freeResults(scalar_plain);
    try std.testing.expectEqualStrings("object:tail", scalar_plain[0].string);

    const empty = try runtime.newTable();
    empty.metatable = false_mt;
    const no_params = try messageNewRawCall(null, &runtime, &.{ .{ .string = "$1" }, .{ .table = empty } });
    defer rt.freeResults(no_params);
    const no_params_plain = try callField(&runtime, no_params[0], "plain", &.{no_params[0]});
    defer rt.freeResults(no_params_plain);
    try std.testing.expectEqualStrings("$1", no_params_plain[0].string);
}

test "message parameter arrays reject holes nested arrays and mixed calling forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const params = try runtime.newTable();
    try params.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "first" });
    try params.rawSet(runtime.allocator, .{ .number = 3 }, .{ .string = "third" });
    try std.testing.expectError(error.MessageParamExpected, messageNewRawCall(null, &runtime, &.{ .{ .string = "$1/$2/$3" }, .{ .table = params } }));
    try std.testing.expectError(error.MixedMessageParameterForms, messageNewCall(null, &runtime, &.{ .{ .string = "key" }, .{ .table = params }, .{ .string = "extra" } }));
    const nested = try runtime.newTable();
    try nested.rawSet(runtime.allocator, .{ .number = 1 }, .{ .table = params });
    try std.testing.expectError(error.MessageParamExpected, messageNewRawCall(null, &runtime, &.{ .{ .string = "$1" }, .{ .table = nested } }));
}

const InterwikiProbe = struct {
    const rows = [_]host_api.InterwikiRow{
        .{ .prefix = "local", .url = "//local.example/$1", .is_local = true, .is_current_wiki = true, .is_protocol_relative = true, .is_transcludable = true },
        .{ .prefix = "ext", .url = "https://ext.example/$1", .is_local = false, .is_current_wiki = false, .is_protocol_relative = false, .is_transcludable = false },
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

    var effect = false;
    const previous_effect = rt.beginLoadDataEffectProbe(&effect);
    defer rt.endLoadDataEffectProbe(previous_effect);
    const all = try callField(&runtime, .{ .table = site }, "interwikiMap", &.{});
    defer rt.freeResults(all);
    try std.testing.expect(effect); // Arbitrary hosts default to page-sensitive.
    const local = all[0].table.rawGet(.{ .string = "local" }).?.table;
    try std.testing.expect(local.rawGet(.{ .string = "isLocal" }).?.boolean);
    try std.testing.expect(local.rawGet(.{ .string = "isCurrentWiki" }).?.boolean);
    try std.testing.expect(local.rawGet(.{ .string = "isTranscludable" }).?.boolean);
    try std.testing.expectEqualStrings("//local.example/$1", local.rawGet(.{ .string = "url" }).?.string);

    const local_only = try callField(&runtime, .{ .table = site }, "interwikiMap", &.{.{ .string = "local" }});
    defer rt.freeResults(local_only);
    try std.testing.expect(local_only[0].table.rawGet(.{ .string = "local" }) != null);
    try std.testing.expect(local_only[0].table.rawGet(.{ .string = "ext" }) == null);
    const external_only = try callField(&runtime, .{ .table = site }, "interwikiMap", &.{.{ .string = "!local" }});
    defer rt.freeResults(external_only);
    try std.testing.expect(external_only[0].table.rawGet(.{ .string = "local" }) == null);
    try std.testing.expect(external_only[0].table.rawGet(.{ .string = "ext" }) != null);
    try std.testing.expect(!external_only[0].table.rawGet(.{ .string = "ext" }).?.table.rawGet(.{ .string = "isTranscludable" }).?.boolean);
    effect = false;
    host.stable_site_interwiki_map = true;
    const from_snapshot = try callField(&runtime, .{ .table = site }, "interwikiMap", &.{});
    defer rt.freeResults(from_snapshot);
    try std.testing.expect(!effect);
}

const WikibaseSitelinkProbe = struct {
    fn get(_: ?*anyopaque, entity_id: []const u8, global_site_id: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, entity_id, "Q42") and std.mem.eql(u8, global_site_id, "enwiki"))
            return "Douglas Adams";
        if (std.mem.eql(u8, entity_id, "Q1") and std.mem.eql(u8, global_site_id, wikibase_site_global_id))
            return null;
        return error.WikibaseSitelinkSnapshotMissing;
    }
};

test "AOT mw wikibase sitelink uses pinned host state and legacy alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const mw = try runtime.newNativeNamespace(.mw);
    try install(&runtime, mw);
    var host = host_api.Host{ .wikibase_sitelink = WikibaseSitelinkProbe.get };
    host_api.set(&runtime, &host);
    const wikibase = mw.rawGet(.{ .string = "wikibase" }).?.table;

    const explicit = try callField(&runtime, .{ .table = wikibase }, "getSitelink", &.{
        .{ .string = "Q42" },
        .{ .string = "enwiki" },
    });
    defer rt.freeResults(explicit);
    try std.testing.expectEqualStrings("Douglas Adams", explicit[0].string);

    const missing = try callField(&runtime, .{ .table = wikibase }, "sitelink", &.{.{ .string = "Q1" }});
    defer rt.freeResults(missing);
    try std.testing.expect(missing[0] == .nil);

    try std.testing.expectError(error.AotCallFailed, callField(&runtime, .{ .table = wikibase }, "getSitelink", &.{
        .{ .string = "Q2" },
        .{ .string = "enwiki" },
    }));
    try std.testing.expectEqualStrings("LuaRaised", runtime.aotErrorName().?);
    try std.testing.expectEqualStrings("Wikibase sitelink snapshot missing entity=Q2 site=enwiki", runtime.last_error.string);
}

const WikibaseEntityTextProbe = struct {
    fn get(_: ?*anyopaque, entity_id: []const u8) !host_api.WikibaseEntityText {
        if (std.mem.eql(u8, entity_id, "Q42"))
            return .{ .label = "Douglas Adams", .description = "English writer and humorist" };
        if (std.mem.eql(u8, entity_id, "Q1"))
            return .{ .label = null, .description = "universe" };
        return error.WikibaseEntityTextSnapshotMissing;
    }
};

test "AOT mw wikibase label and description use pinned host state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const mw = try runtime.newNativeNamespace(.mw);
    try install(&runtime, mw);
    var host = host_api.Host{ .wikibase_entity_text = WikibaseEntityTextProbe.get };
    host_api.set(&runtime, &host);
    const wikibase = mw.rawGet(.{ .string = "wikibase" }).?.table;

    const label = try callField(&runtime, .{ .table = wikibase }, "getLabel", &.{.{ .string = "q42" }});
    defer rt.freeResults(label);
    try std.testing.expectEqualStrings("Douglas Adams", label[0].string);
    const description = try callField(&runtime, .{ .table = wikibase }, "getDescription", &.{.{ .string = "Q42" }});
    defer rt.freeResults(description);
    try std.testing.expectEqualStrings("English writer and humorist", description[0].string);
    const absent_label = try callField(&runtime, .{ .table = wikibase }, "getLabel", &.{.{ .string = "Q1" }});
    defer rt.freeResults(absent_label);
    try std.testing.expect(absent_label[0] == .nil);
    const invalid = try callField(&runtime, .{ .table = wikibase }, "getLabel", &.{.{ .string = "bad" }});
    defer rt.freeResults(invalid);
    try std.testing.expect(invalid[0] == .nil);

    try std.testing.expectError(error.AotCallFailed, callField(&runtime, .{ .table = wikibase }, "getDescription", &.{.{ .string = "Q2" }}));
    try std.testing.expectEqualStrings("LuaRaised", runtime.aotErrorName().?);
    try std.testing.expectEqualStrings("Wikibase entity-text snapshot missing entity=Q2", runtime.last_error.string);
}

const LocalizedExternalDataProbe = struct {
    const source =
        \\{"license":"CC0-1.0","description":{"en":"Identifier limits","uk":"Межі"},"schema":{"fields":[{"name":"id","type":"string","title":{"ar":"","en":"Identifier"}},{"name":"limit","type":"number"},{"name":"label","type":"localized","title":{"en":"Label"}}]},"data":[["PMID",42900000,{"fr":"first stored label","uk":"second stored label"}],["PMC",15000000,null]]}
    ;

    fn get(_: ?*anyopaque, title: []const u8) !?host_api.ExternalData {
        if (std.mem.eql(u8, title, "Malformed.tab"))
            return .{ .content_model = "Tabular.JsonConfig", .source = "{" };
        if (std.mem.eql(u8, title, "Overflow.tab"))
            return .{ .content_model = "Tabular.JsonConfig", .source = "{\"schema\":{\"fields\":[{\"name\":\"n\",\"type\":\"number\"}]},\"data\":[[1e9999]]}" };
        return .{ .content_model = "Tabular.JsonConfig", .source = source };
    }

    fn fallbacks(_: ?*anyopaque, language: []const u8) ![]const []const u8 {
        if (std.mem.eql(u8, language, "ar")) return &.{};
        if (std.mem.eql(u8, language, "fr")) return &.{ "de", "uk" };
        return error.LanguageFallbackSnapshotMissing;
    }

    fn message(_: ?*anyopaque, _: std.mem.Allocator, language: []const u8, key: []const u8) !?host_api.InterfaceMessage {
        if (!std.mem.eql(u8, language, "ar")) return error.InterfaceMessageSnapshotMissing;
        if (std.mem.eql(u8, key, "jsonconfig-license-name-CC0-1.0"))
            return .{ .source = "المشاع الإبداعي صفر" };
        if (std.mem.eql(u8, key, "jsonconfig-license-url-CC0-1.0"))
            return .{ .source = "https://creativecommons.org/publicdomain/zero/1.0/" };
        return error.InterfaceMessageSnapshotMissing;
    }
};

test "AOT Commons localization uses target language captured license and fresh nested data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var registry = try rt.namespace_registry.Registry.init(std.testing.allocator, rt.namespace_registry.english_test_fixture);
    defer registry.deinit();
    registry.content_language = "ar";
    runtime.namespace_catalog = &registry;
    var host = host_api.Host{
        .external_data = LocalizedExternalDataProbe.get,
        .language_fallbacks = LocalizedExternalDataProbe.fallbacks,
        .interface_message = LocalizedExternalDataProbe.message,
    };
    host_api.set(&runtime, &host);
    const mw = try runtime.newNativeNamespace(.mw);
    try install(&runtime, mw);
    const api = mw.rawGet(.{ .string = "ext" }).?.table.rawGet(.{ .string = "data" }).?;
    const first = try callField(&runtime, api, "get", &.{.{ .string = "Limits.tab" }});
    defer rt.freeResults(first);
    const result = first[0].table;
    try std.testing.expectEqualStrings("Identifier limits", result.rawGet(.{ .string = "description" }).?.string);
    const license = result.rawGet(.{ .string = "license" }).?.table;
    try std.testing.expectEqualStrings("CC0-1.0", license.rawGet(.{ .string = "code" }).?.string);
    try std.testing.expectEqualStrings("المشاع الإبداعي صفر", license.rawGet(.{ .string = "text" }).?.string);
    try std.testing.expectEqualStrings("https://creativecommons.org/publicdomain/zero/1.0/", license.rawGet(.{ .string = "url" }).?.string);
    const fields = result.rawGet(.{ .string = "schema" }).?.table.rawGet(.{ .string = "fields" }).?.table;
    try std.testing.expect(fields.rawGetNumber(0) == null);
    try std.testing.expectEqualStrings("", fields.rawGetNumber(1).?.table.rawGet(.{ .string = "title" }).?.string);
    try std.testing.expectEqualStrings("limit", fields.rawGetNumber(2).?.table.rawGet(.{ .string = "title" }).?.string);
    const rows = result.rawGet(.{ .string = "data" }).?.table;
    try std.testing.expect(rows.rawGetNumber(0) == null);
    try std.testing.expectEqual(@as(f64, 42900000), rows.rawGetNumber(1).?.table.rawGetNumber(2).?.number);
    try std.testing.expectEqualStrings("first stored label", rows.rawGetNumber(1).?.table.rawGetNumber(3).?.string);
    try std.testing.expect(rows.rawGetNumber(2).?.table.rawGetNumber(3) == null);
    try rows.rawGetNumber(1).?.table.rawSet(runtime.allocator, .{ .number = 2 }, .{ .number = 7 });
    try license.rawSet(runtime.allocator, .{ .string = "text" }, .{ .string = "changed" });
    const again = try callField(&runtime, api, "get", &.{ .{ .string = "Limits.tab" }, .nil });
    defer rt.freeResults(again);
    try std.testing.expectEqual(@as(f64, 42900000), again[0].table.rawGet(.{ .string = "data" }).?.table.rawGetNumber(1).?.table.rawGetNumber(2).?.number);
    try std.testing.expectEqualStrings("المشاع الإبداعي صفر", again[0].table.rawGet(.{ .string = "license" }).?.table.rawGet(.{ .string = "text" }).?.string);

    host.interface_message = null;
    host.language_fallbacks = null;
    const raw = try callField(&runtime, api, "get", &.{ .{ .string = "Limits.tab" }, .{ .string = "_" } });
    defer rt.freeResults(raw);
    try std.testing.expectEqualStrings("CC0-1.0", raw[0].table.rawGet(.{ .string = "license" }).?.string);
    try std.testing.expect(raw[0].table.rawGet(.{ .string = "description" }).? == .table);
    host.language_fallbacks = LocalizedExternalDataProbe.fallbacks;
    try std.testing.expectError(error.InterfaceMessageSnapshotMissing, externalDataGetCall(null, &runtime, &.{.{ .string = "Limits.tab" }}));
}

test "Commons localized strings preserve fallback order exact empty values and first JSON member" {
    var host = host_api.Host{ .language_fallbacks = LocalizedExternalDataProbe.fallbacks };
    const cases = .{
        .{ "ar", "{\"en\":\"fallback\",\"ar\":\"\"}", "" },
        .{ "fr", "{\"en\":\"English\",\"uk\":\"second\",\"de\":\"first\"}", "first" },
        .{ "ar", "{\"en\":\"English\",\"fr\":\"French\"}", "English" },
        .{ "ar", "{\"uk\":\"first\",\"de\":\"second\"}", "first" },
        .{ "ar", "{\"uk\":\"0\",\"de\":\"second\"}", "" },
        .{ "ar", "{\"ar\":\"0\"}", "0" },
        .{ "en", "{}", "" },
    };
    inline for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case[1], .{});
        defer parsed.deinit();
        const result = try localizedJsonString(&host, case[0], parsed.value);
        try std.testing.expectEqualStrings(case[2], result.string);
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"en\":\"fallback\"}", .{});
    defer parsed.deinit();
    host.language_fallbacks = null;
    try std.testing.expectError(error.LanguageFallbackSnapshotMissing, localizedJsonString(&host, "ar", parsed.value));
}

test "Commons JSON allocation failure remains recoverable OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .external_data = LocalizedExternalDataProbe.get };
    host_api.set(&runtime, &host);
    const original = runtime.allocator;
    defer runtime.allocator = original;
    var failing = std.testing.FailingAllocator.init(original, .{ .fail_index = 0 });
    runtime.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, externalDataGetCall(null, &runtime, &.{ .{ .string = "Limits.tab" }, .{ .string = "_" } }));
    runtime.allocator = original;
    try std.testing.expectError(error.InvalidExternalDataSnapshot, externalDataGetCall(null, &runtime, &.{ .{ .string = "Malformed.tab" }, .{ .string = "_" } }));
    try std.testing.expectError(error.InvalidExternalDataSnapshot, externalDataGetCall(null, &runtime, &.{ .{ .string = "Overflow.tab" }, .{ .string = "_" } }));
}
