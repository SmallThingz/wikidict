const std = @import("std");
const rt = @import("zig_runtime");
const namespace_lib = @import("namespaces.zig");
const host_api = @import("host.zig");
const text_lib = @import("text.zig");
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

    const host = host_api.get(runtime) orelse return error.NotImplemented;
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
    var state = DumpState{ .runtime = runtime };
    defer state.deinit();
    var out: std.ArrayList(u8) = .empty;
    try state.dumpValue(&out, if (args.len == 0) .nil else args[0], 0, true);
    return one(.{ .string = try out.toOwnedSlice(runtime.allocator) });
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

fn tableField(table: *rt.Table, name: []const u8) ?Value {
    return table.rawGet(.{ .string = name });
}

fn localizedEnglish(value: Value) !Value {
    if (value != .table) return error.InvalidExternalDataSnapshot;
    const english = tableField(value.table, "en") orelse return error.NotImplemented;
    if (english != .string) return error.InvalidExternalDataSnapshot;
    return english;
}

fn englishLicense(runtime: *rt.Context, code: []const u8) !Value {
    if (!std.mem.eql(u8, code, "CC-BY-SA-4.0")) return error.NotImplemented;
    const license = try runtime.newTable();
    try license.rawSet(runtime.allocator, .{ .string = "code" }, .{ .string = "CC-BY-SA-4.0" });
    try license.rawSet(runtime.allocator, .{ .string = "text" }, .{ .string = "Creative Commons Attribution-Share Alike 4.0" });
    try license.rawSet(runtime.allocator, .{ .string = "url" }, .{ .string = "https://creativecommons.org/licenses/by-sa/4.0/deed.en" });
    return .{ .table = license };
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

fn localizedTabular(runtime: *rt.Context, raw: *rt.Table) !Value {
    const out = try runtime.newTable();
    if (tableField(raw, "description")) |description|
        try out.rawSet(runtime.allocator, .{ .string = "description" }, try localizedEnglish(description));
    if (tableField(raw, "license")) |license| {
        if (license != .string) return error.InvalidExternalDataSnapshot;
        try out.rawSet(runtime.allocator, .{ .string = "license" }, try englishLicense(runtime, license.string));
    }
    if (tableField(raw, "sources")) |sources|
        try out.rawSet(runtime.allocator, .{ .string = "sources" }, sources);
    if (tableField(raw, "mediawikiCategories")) |categories|
        try out.rawSet(runtime.allocator, .{ .string = "mediawikiCategories" }, categories);

    const schema_value = tableField(raw, "schema") orelse return error.InvalidExternalDataSnapshot;
    if (schema_value != .table) return error.InvalidExternalDataSnapshot;
    const fields_value = tableField(schema_value.table, "fields") orelse return error.InvalidExternalDataSnapshot;
    if (fields_value != .table) return error.InvalidExternalDataSnapshot;
    const out_schema = try runtime.newTable();
    const out_fields = try runtime.newTable();
    var localized_columns: std.ArrayList(bool) = .empty;
    defer localized_columns.deinit(runtime.allocator);

    var field_index: usize = 1;
    while (fields_value.table.rawGetNumber(@floatFromInt(field_index))) |field_value| : (field_index += 1) {
        if (field_value != .table) return error.InvalidExternalDataSnapshot;
        const name = tableField(field_value.table, "name") orelse return error.InvalidExternalDataSnapshot;
        const field_type = tableField(field_value.table, "type") orelse return error.InvalidExternalDataSnapshot;
        if (name != .string or field_type != .string) return error.InvalidExternalDataSnapshot;
        const out_field = try runtime.newTable();
        try out_field.rawSet(runtime.allocator, .{ .string = "name" }, name);
        try out_field.rawSet(runtime.allocator, .{ .string = "type" }, field_type);
        const title = if (tableField(field_value.table, "title")) |value| try localizedEnglish(value) else name;
        try out_field.rawSet(runtime.allocator, .{ .string = "title" }, title);
        try out_fields.rawSet(runtime.allocator, .{ .number = @floatFromInt(field_index) }, .{ .table = out_field });
        try localized_columns.append(runtime.allocator, std.mem.eql(u8, field_type.string, "localized"));
    }
    try out_schema.rawSet(runtime.allocator, .{ .string = "fields" }, .{ .table = out_fields });
    try out.rawSet(runtime.allocator, .{ .string = "schema" }, .{ .table = out_schema });

    const data_value: Value = tableField(raw, "data") orelse .{ .table = try runtime.newTable() };
    if (data_value != .table) return error.InvalidExternalDataSnapshot;
    var has_localized = false;
    for (localized_columns.items) |is_localized| has_localized = has_localized or is_localized;
    if (!has_localized) {
        try out.rawSet(runtime.allocator, .{ .string = "data" }, data_value);
        return .{ .table = out };
    }

    const out_data = try runtime.newTable();
    var row_index: usize = 1;
    while (data_value.table.rawGetNumber(@floatFromInt(row_index))) |row_value| : (row_index += 1) {
        if (row_value != .table) return error.InvalidExternalDataSnapshot;
        const out_row = try runtime.newTable();
        for (localized_columns.items, 0..) |is_localized, column_zero| {
            const column: f64 = @floatFromInt(column_zero + 1);
            const value = row_value.table.rawGetNumber(column) orelse .nil;
            const converted = if (is_localized and value != .nil) try localizedEnglish(value) else value;
            if (converted != .nil) try out_row.rawSet(runtime.allocator, .{ .number = column }, converted);
        }
        try out_data.rawSet(runtime.allocator, .{ .number = @floatFromInt(row_index) }, .{ .table = out_row });
    }
    try out.rawSet(runtime.allocator, .{ .string = "data" }, .{ .table = out_data });
    return .{ .table = out };
}

fn externalDataGetCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const raw = if (args.len < 2 or args[1] == .nil)
        false
    else if (args[1] != .string)
        return error.StringExpected
    else if (std.mem.eql(u8, args[1].string, "_"))
        true
    else if (std.mem.eql(u8, args[1].string, "en"))
        false
    else
        return error.NotImplemented;

    if (!std.mem.endsWith(u8, args[0].string, ".tab")) return error.NotImplemented;
    const host = host_api.get(runtime) orelse return error.NotImplemented;
    const get = host.external_data orelse return error.NotImplemented;
    const entry = (try get(host.ctx, args[0].string)) orelse return one(.{ .boolean = false });
    if (!std.mem.eql(u8, entry.content_model, "Tabular.JsonConfig")) return error.NotImplemented;
    const decoded = text_lib.jsonDecodeValue(runtime, entry.source, text_lib.json_preserve_keys) catch return error.InvalidExternalDataSnapshot;
    if (decoded != .table) return error.InvalidExternalDataSnapshot;
    try reindexTabularRaw(runtime, decoded.table);
    return one(if (raw) decoded else try localizedTabular(runtime, decoded.table));
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

const wikibase_site_global_id = "enwiktionary";
const wikibase_entity_url_prefix = "https://www.wikidata.org/wiki/Special:EntityPage/";

fn validWikibaseNumericPart(digits: []const u8) bool {
    if (digits.len == 0 or digits[0] == '0') return false;
    const value = std.fmt.parseInt(u32, digits, 10) catch return false;
    return value <= 2_147_483_647;
}

fn canonicalWikibaseEntityId(runtime: *rt.Context, raw: []const u8) !?[]const u8 {
    if (raw.len < 2) return null;
    if (raw[0] == 'L') {
        if (std.mem.indexOfScalar(u8, raw, '-')) |dash| {
            if (dash <= 1 or dash + 2 >= raw.len) return null;
            if (raw[dash + 1] != 'F' and raw[dash + 1] != 'S') return null;
            if (!std.ascii.isDigit(raw[1]) or raw[1] == '0') return null;
            for (raw[1..dash]) |c| if (!std.ascii.isDigit(c)) return null;
            const suffix = raw[dash + 2 ..];
            if (suffix.len == 0 or suffix[0] == '0') return null;
            for (suffix) |c| if (!std.ascii.isDigit(c)) return null;
            return try runtime.allocator.dupe(u8, raw);
        }
    }
    const prefix = std.ascii.toUpper(raw[0]);
    if (prefix != 'Q' and prefix != 'P' and prefix != 'L') return null;
    if (!validWikibaseNumericPart(raw[1..])) return null;
    const out = try runtime.allocator.alloc(u8, raw.len);
    out[0] = prefix;
    @memcpy(out[1..], raw[1..]);
    return out;
}

fn wikibaseGetGlobalSiteIdCall(_: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    return one(.{ .string = wikibase_site_global_id });
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

pub fn install(runtime: *rt.Context, mw: *rt.Table) !void {
    try setMwNative(runtime, mw, "dumpObject", dumpObjectCall);
    try setMwNative(runtime, mw, "log", noOpCall);
    try setMwNative(runtime, mw, "logObject", noOpCall);
    try setMwNative(runtime, mw, "addWarning", addWarningCall);
    try setMwNative(runtime, mw, "incrementExpensiveFunctionCount", noOpCall);
    try setMwNative(runtime, mw, "isSubsting", falseCall);

    const site = try runtime.newTable();
    const namespaces = try namespace_lib.makeTable(runtime);
    try site.rawSet(runtime.allocator, .{ .string = "namespaces" }, .{ .table = namespaces });
    const stats = try runtime.newTable();
    try setNative(runtime, stats, "pagesInCategory", pagesInCategoryCall);
    inline for (.{ "pagesInNamespace", "usersInGroup" }) |name|
        try setNative(runtime, stats, name, notImplementedCall);
    const stats_mt = try runtime.newTable();
    try stats_mt.rawSet(runtime.allocator, .{ .string = "__index" }, try runtime.newNative(null, statsIndexCall));
    stats.metatable = stats_mt;
    try site.rawSet(runtime.allocator, .{ .string = "stats" }, .{ .table = stats });
    try setNative(runtime, site, "interwikiMap", interwikiMapCall);
    try mw.rawSetNativeField(.mw, "site", .{ .table = site });

    const ext = try runtime.newTable();
    const ext_data = try runtime.newTable();
    try setNative(runtime, ext_data, "get", externalDataGetCall);
    try ext.rawSet(runtime.allocator, .{ .string = "data" }, .{ .table = ext_data });
    try mw.rawSetNativeField(.mw, "ext", .{ .table = ext });

    const wikibase = try runtime.newTable();
    inline for (.{
        "getEntity",
        "getEntityIdForTitle",
        "getDescription",
        "getLabel",
        "getEntityIdForCurrentPage",
        "getSitelink",
        "getBestStatements",
        "getLabelWithLang",
        "getLabelByLang",
        "getAllStatements",
        "formatValue",
        "entityExists",
        "sitelink",
    }) |name| try setNative(runtime, wikibase, name, notImplementedCall);
    try setNative(runtime, wikibase, "getEntityUrl", wikibaseGetEntityUrlCall);
    try setNative(runtime, wikibase, "getGlobalSiteId", wikibaseGetGlobalSiteIdCall);
    try setNative(runtime, wikibase, "isValidEntityId", wikibaseIsValidEntityIdCall);
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
};

test "AOT mw ext data reads explicit tabular snapshot exactly and fails closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .external_data = ExternalDataProbe.get };
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
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
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
