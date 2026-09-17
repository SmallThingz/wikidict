const std = @import("std");
const rt = @import("zig_runtime");
const host_api = @import("host.zig");
const html_entities = @import("shared_xml_decode").html_entities;
const Value = rt.Value;

const Host = struct {
    ustring: *rt.Table,
};

fn one(_: std.mem.Allocator, value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

fn setNative(runtime: *rt.Context, table: *rt.Table, comptime name: []const u8, host: ?*anyopaque, comptime call: anytype) !void {
    try table.rawSetNativeField(.text, name, try runtime.newNative(host, call));
}
const TextGsplitCtx = struct {
    source: []const u8,
    pattern: []const u8,
    plain: bool,
    find: Value,
    sub: Value,
    next_index: i64 = 1,
    codepoint_len: i64,
    done: bool = false,
};

fn textGsplitCtx(host: *const Host, source: []const u8, pattern: []const u8, plain: bool) !TextGsplitCtx {
    const find = host.ustring.rawGet(.{ .string = "find" }) orelse return error.NotImplemented;
    const sub = host.ustring.rawGet(.{ .string = "sub" }) orelse return error.NotImplemented;
    const count = std.unicode.utf8CountCodepoints(source) catch return error.InvalidUtf8;
    return .{
        .source = source,
        .pattern = pattern,
        .plain = plain,
        .find = find,
        .sub = sub,
        .codepoint_len = @intCast(count),
    };
}

fn textGsplitNext(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const a = runtime.allocator;
    const ctx: *TextGsplitCtx = @ptrCast(@alignCast(ctx_raw.?));
    if (ctx.done) return &.{};
    const found = try runtime.callValue(ctx.find, &.{
        .{ .string = ctx.source },
        .{ .string = ctx.pattern },
        .{ .number = @floatFromInt(ctx.next_index) },
        .{ .boolean = ctx.plain },
    });
    defer rt.freeResults(found);

    if (found.len == 0 or found[0] == .nil) {
        const tail = try runtime.callValue(ctx.sub, &.{
            .{ .string = ctx.source },
            .{ .number = @floatFromInt(ctx.next_index) },
        });
        defer rt.freeResults(tail);
        ctx.done = true;
        return one(a, if (tail.len == 0) .{ .string = "" } else tail[0]);
    }
    if (found.len < 2 or found[0] != .number or found[1] != .number) return error.InvalidSplitMatch;
    const first: i64 = @intFromFloat(@trunc(found[0].number));
    const last: i64 = @intFromFloat(@trunc(found[1].number));

    if (last < first) {
        const piece = try runtime.callValue(ctx.sub, &.{
            .{ .string = ctx.source },
            .{ .number = @floatFromInt(ctx.next_index) },
            .{ .number = @floatFromInt(first) },
        });
        defer rt.freeResults(piece);
        if (first < ctx.codepoint_len) ctx.next_index = first + 1 else ctx.done = true;
        return one(a, if (piece.len == 0) .{ .string = "" } else piece[0]);
    }

    const value: Value = if (first > ctx.next_index) blk: {
        const piece = try runtime.callValue(ctx.sub, &.{
            .{ .string = ctx.source },
            .{ .number = @floatFromInt(ctx.next_index) },
            .{ .number = @floatFromInt(first - 1) },
        });
        defer rt.freeResults(piece);
        break :blk if (piece.len == 0) .{ .string = "" } else piece[0];
    } else .{ .string = "" };
    ctx.next_index = last + 1;
    return one(a, value);
}

fn textGsplitCall(host_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len < 2 or args[0] != .string or args[1] != .string) return error.StringExpected;
    const host: *Host = @ptrCast(@alignCast(host_raw orelse return error.MissingTextHost));
    const ctx = try a.create(TextGsplitCtx);
    ctx.* = try textGsplitCtx(host, args[0].string, args[1].string, args.len > 2 and args[2].truthy());
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    out[0] = try runtime.newNative(ctx, textGsplitNext);
    out[1] = .nil;
    out[2] = .nil;
    return out;
}

fn textSplitCall(host_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len < 2 or args[0] != .string or args[1] != .string) return error.StringExpected;
    const host: *Host = @ptrCast(@alignCast(host_raw orelse return error.MissingTextHost));
    var split = try textGsplitCtx(host, args[0].string, args[1].string, args.len > 2 and args[2].truthy());
    const out = try runtime.newTable();
    var index: usize = 1;
    while (true) {
        const result = try textGsplitNext(&split, runtime, &.{});
        defer rt.freeResults(result);
        if (result.len == 0) break;
        try out.rawSet(runtime.allocator, .{ .number = @floatFromInt(index) }, result[0]);
        index += 1;
    }
    return one(a, .{ .table = out });
}

fn replaceLiteralAlloc(a: std.mem.Allocator, source: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (needle.len == 0 or std.mem.indexOf(u8, source, needle) == null) return source;
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, needle)) |at| {
        try out.appendSlice(a, source[pos..at]);
        try out.appendSlice(a, replacement);
        pos = at + needle.len;
    }
    try out.appendSlice(a, source[pos..]);
    return out.toOwnedSlice(a);
}

fn nowikiLineEscape(c: u8) ?[]const u8 {
    return switch (c) {
        '!' => "&#33;",
        '#' => "&#35;",
        '*' => "&#42;",
        ':' => "&#58;",
        ' ' => "&#32;",
        '\n' => "&#10;",
        '\r' => "&#13;",
        '\t' => "&#9;",
        else => null,
    };
}

fn appendNowikiPrimary(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8) !void {
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        const repl: ?[]const u8 = switch (c) {
            '"' => "&#34;",
            '&' => "&#38;",
            '\'' => "&#39;",
            '<' => "&#60;",
            '=' => "&#61;",
            '>' => "&#62;",
            '[' => "&#91;",
            ']' => "&#93;",
            '{' => "&#123;",
            '|' => "&#124;",
            '}' => "&#125;",
            ';' => "&#59;",
            else => null,
        };
        if (repl) |r| try out.appendSlice(a, r) else try out.append(a, c);
        i += 1;
    }
}

fn protectNowikiLineStarts(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var at_line_start = true;
    while (i < source.len) {
        if (at_line_start) {
            if (i + 4 <= source.len and std.mem.eql(u8, source[i .. i + 4], "----")) {
                try out.appendSlice(a, "&#45;---");
                i += 4;
                at_line_start = false;
                continue;
            }
            if (nowikiLineEscape(source[i])) |r| {
                try out.appendSlice(a, r);
                i += 1;
                at_line_start = false;
                continue;
            }
        }
        const c = source[i];
        try out.append(a, c);
        i += 1;
        at_line_start = false;
        if (c == '\n' or c == '\r') {
            if (i + 4 <= source.len and std.mem.eql(u8, source[i .. i + 4], "----")) {
                try out.appendSlice(a, "&#45;---");
                i += 4;
                at_line_start = false;
            } else if (i < source.len) {
                if (nowikiLineEscape(source[i])) |r| {
                    try out.appendSlice(a, r);
                    i += 1;
                    at_line_start = false;
                } else at_line_start = false;
            } else at_line_start = false;
        }
    }
    return out.toOwnedSlice(a);
}

fn protectMagicLinkWhitespace(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        var prefix_len: usize = 0;
        if (std.mem.startsWith(u8, source[i..], "ISBN")) prefix_len = 4 else if (std.mem.startsWith(u8, source[i..], "RFC")) prefix_len = 3 else if (std.mem.startsWith(u8, source[i..], "PMID")) prefix_len = 4;
        if (prefix_len != 0 and i + prefix_len < source.len) {
            const ws = source[i + prefix_len];
            const entity: ?[]const u8 = switch (ws) {
                ' ' => "&#32;",
                '\t' => "&#9;",
                '\r' => "&#13;",
                '\n' => "&#10;",
                0x0c => "&#12;",
                else => null,
            };
            if (entity) |e| {
                try out.appendSlice(a, source[i .. i + prefix_len]);
                try out.appendSlice(a, e);
                i += prefix_len + 1;
                continue;
            }
        }
        try out.append(a, source[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn protectNowikiProtocols(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    const protocols = [_][]const u8{
        "bitcoin", "ftp",    "ftps", "geo",    "git",  "gopher",    "http", "https", "irc",  "ircs",
        "magnet",  "mailto", "mms",  "news",   "nntp", "redis",     "sftp", "sip",   "sips", "sms",
        "ssh",     "svn",    "tel",  "telnet", "urn",  "worldwind", "xmpp",
    };
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        var matched: ?[]const u8 = null;
        for (protocols) |protocol| {
            if (i + protocol.len < source.len and source[i + protocol.len] == ':' and std.ascii.eqlIgnoreCase(source[i .. i + protocol.len], protocol)) {
                matched = protocol;
                break;
            }
        }
        if (matched) |protocol| {
            try out.appendSlice(a, source[i .. i + protocol.len]);
            try out.appendSlice(a, "&#58;");
            i += protocol.len + 1;
        } else {
            try out.append(a, source[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

fn textNowikiCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    var stage1: std.ArrayList(u8) = .empty;
    try appendNowikiPrimary(&stage1, a, args[0].string);
    var text: []const u8 = try stage1.toOwnedSlice(a);
    text = try protectNowikiLineStarts(a, text);
    text = try replaceLiteralAlloc(a, text, "!!", "&#33;!");
    text = try replaceLiteralAlloc(a, text, "__", "_&#95;");
    text = try replaceLiteralAlloc(a, text, "://", "&#58;//");
    text = try replaceLiteralAlloc(a, text, "~~~", "~~&#126;");
    text = try replaceLiteralAlloc(a, text, "＿", "&#xFF3F;");
    if (text.len != 0) {
        const first: ?[]const u8 = switch (text[0]) {
            '-' => "&#45;",
            '+' => "&#43;",
            '_' => "&#95;",
            '~' => "&#126;",
            else => null,
        };
        if (first) |r| text = try std.fmt.allocPrint(a, "{s}{s}", .{ r, text[1..] });
    }
    if (text.len != 0) {
        const last: ?[]const u8 = switch (text[text.len - 1]) {
            '_' => "&#95;",
            '~' => "&#126;",
            '\r' => "&#13;",
            '\n' => "&#10;",
            '\t' => "&#9;",
            else => null,
        };
        if (last) |r| text = try std.fmt.allocPrint(a, "{s}{s}", .{ text[0 .. text.len - 1], r });
    }
    text = try protectMagicLinkWhitespace(a, text);
    text = try protectNowikiProtocols(a, text);
    return one(a, .{ .string = text });
}

fn textUnstripCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const source = args[0].string;
    if (std.mem.indexOfScalar(u8, source, 0x7f) == null)
        return one(runtime.allocator, .{ .string = source });
    if (host_api.get(runtime)) |host| if (host.text_unstrip_no_wiki) |call| {
        const restored = try call(host.ctx, runtime.allocator, source);
        if (std.mem.indexOfScalar(u8, restored, 0x7f) != null) return error.NotImplemented;
        return one(runtime.allocator, .{ .string = restored });
    };
    return error.NotImplemented;
}

fn textUnstripNoWikiCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    if (host_api.get(runtime)) |host| if (host.text_unstrip_no_wiki) |call|
        return one(runtime.allocator, .{ .string = try call(host.ctx, runtime.allocator, args[0].string) });
    return textUnstripCall(null, runtime, args);
}

const marker_prefix = "\x7f'\"`UNIQ--";
const marker_suffix = "-QINU`\"'\x7f";

fn validMarkerBody(body: []const u8) bool {
    if (body.len == 0) return false;
    for (body) |ch| switch (ch) {
        0x7f, '<', '>', '&', '\'', '"' => return false,
        else => {},
    };
    return true;
}

pub fn killMarkersAlloc(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, source, marker_prefix) == null) return source;
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, marker_prefix)) |at| {
        try out.appendSlice(a, source[pos..at]);
        const body_start = at + marker_prefix.len;
        const suffix_at = std.mem.indexOfPos(u8, source, body_start, marker_suffix) orelse {
            try out.appendSlice(a, source[at..]);
            pos = source.len;
            break;
        };
        if (validMarkerBody(source[body_start..suffix_at])) {
            pos = suffix_at + marker_suffix.len;
        } else {
            try out.append(a, source[at]);
            pos = at + 1;
        }
    }
    try out.appendSlice(a, source[pos..]);
    return out.toOwnedSlice(a);
}

fn textKillMarkersCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    return one(runtime.allocator, .{ .string = try killMarkersAlloc(runtime.allocator, args[0].string) });
}

fn appendHtmlEncoded(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8) !void {
    var i: usize = 0;
    while (i < source.len) {
        if (i + 1 < source.len and source[i] == 0xc2 and source[i + 1] == 0xa0) {
            try out.appendSlice(a, "&nbsp;");
            i += 2;
            continue;
        }
        const replacement: ?[]const u8 = switch (source[i]) {
            '>' => "&gt;",
            '<' => "&lt;",
            '&' => "&amp;",
            '"' => "&quot;",
            '\'' => "&#039;",
            else => null,
        };
        if (replacement) |value| try out.appendSlice(a, value) else try out.append(a, source[i]);
        i += 1;
    }
}

fn textEncodeCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    if (args.len > 1 and args[1] != .nil) return error.NotImplemented;
    var out: std.ArrayList(u8) = .empty;
    try appendHtmlEncoded(&out, runtime.allocator, args[0].string);
    return one(runtime.allocator, .{ .string = try out.toOwnedSlice(runtime.allocator) });
}

fn validTagAttributeName(name: []const u8) bool {
    for (name) |ch| switch (ch) {
        '\t', '\r', '\n', 0x0c, ' ', '/', '<', '>', '"', '\'', '=' => return false,
        else => {},
    };
    return true;
}

fn appendTagAttribute(out: *std.ArrayList(u8), runtime: *rt.Context, name: []const u8, value: Value) !void {
    if (!validTagAttributeName(name)) return error.InvalidTagAttribute;
    if (value == .boolean) {
        if (value.boolean) {
            try out.append(runtime.allocator, ' ');
            try out.appendSlice(runtime.allocator, name);
        }
        return;
    }
    const raw = switch (value) {
        .string => |text| text,
        .number => |number| try rt.numberToString(runtime.allocator, number),
        else => return error.InvalidTagAttributeValue,
    };
    try out.append(runtime.allocator, ' ');
    try out.appendSlice(runtime.allocator, name);
    try out.appendSlice(runtime.allocator, "=\"");
    try appendHtmlEncoded(out, runtime.allocator, raw);
    try out.append(runtime.allocator, '"');
}

fn appendTagAttributes(out: *std.ArrayList(u8), runtime: *rt.Context, table: *rt.Table) !void {
    const object = Value{ .table = table };
    if (table.metatable) |mt| if (mt.rawGet(.{ .string = "__pairs" })) |method| {
        const triple = try runtime.callValue(method, &.{object});
        defer rt.freeResults(triple);
        const iter = if (triple.len > 0) triple[0] else Value.nil;
        const state = if (triple.len > 1) triple[1] else Value.nil;
        var key = if (triple.len > 2) triple[2] else Value.nil;
        while (true) {
            const result = try runtime.callValue(iter, &.{ state, key });
            defer rt.freeResults(result);
            if (result.len == 0 or result[0] == .nil) break;
            key = result[0];
            if (key != .string) return error.InvalidTagAttribute;
            try appendTagAttribute(out, runtime, key.string, if (result.len > 1) result[1] else .nil);
        }
        return;
    };
    var it = table.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* != .string) return error.InvalidTagAttribute;
        try appendTagAttribute(out, runtime, entry.key_ptr.string, entry.value_ptr.*);
    }
}

fn textTagCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0) return error.StringExpected;
    var name: []const u8 = undefined;
    var attrs: ?*rt.Table = null;
    var content: Value = .nil;

    if (args[0] == .table) {
        const spec = args[0].table;
        const object = Value{ .table = spec };
        const name_value = try runtime.getIndex(object, .{ .string = "name" });
        if (name_value != .string) return error.StringExpected;
        name = name_value.string;
        switch (try runtime.getIndex(object, .{ .string = "attrs" })) {
            .nil => {},
            .table => |table| attrs = table,
            else => return error.TableExpected,
        }
        content = try runtime.getIndex(object, .{ .string = "content" });
    } else {
        if (args[0] != .string) return error.StringExpected;
        name = args[0].string;
        if (args.len > 1) switch (args[1]) {
            .nil => {},
            .table => |table| attrs = table,
            else => return error.TableExpected,
        };
        if (args.len > 2) content = args[2];
    }

    var out: std.ArrayList(u8) = .empty;
    try out.append(runtime.allocator, '<');
    try out.appendSlice(runtime.allocator, name);
    if (attrs) |table| try appendTagAttributes(&out, runtime, table);

    if (content == .nil) {
        try out.append(runtime.allocator, '>');
    } else if (content == .boolean and !content.boolean) {
        try out.appendSlice(runtime.allocator, " />");
    } else if (content == .string or content == .number) {
        try out.append(runtime.allocator, '>');
        try out.appendSlice(runtime.allocator, if (content == .string) content.string else try rt.numberToString(runtime.allocator, content.number));
        try out.appendSlice(runtime.allocator, "</");
        try out.appendSlice(runtime.allocator, name);
        try out.append(runtime.allocator, '>');
    } else return error.InvalidTagContent;
    return one(runtime.allocator, .{ .string = try out.toOwnedSlice(runtime.allocator) });
}

const json_preserve_keys: u32 = 1;
const json_try_fixing: u32 = 2;
const json_pretty: u32 = 4;

fn jsonFlags(args: []const Value) !u32 {
    if (args.len < 2 or args[1] == .nil) return 0;
    if (args[1] != .number) return error.NumberExpected;
    const raw = args[1].number;
    if (!std.math.isFinite(raw) or raw != @trunc(raw) or raw < 0 or raw > std.math.maxInt(u32))
        return error.InvalidJsonFlags;
    return @intFromFloat(raw);
}

fn jsonObjectKey(runtime: *rt.Context, raw: []const u8) !Value {
    const integer = std.fmt.parseInt(i64, raw, 10) catch
        return .{ .string = try runtime.allocator.dupe(u8, raw) };
    var buffer: [32]u8 = undefined;
    const canonical = try std.fmt.bufPrint(&buffer, "{d}", .{integer});
    if (!std.mem.eql(u8, canonical, raw))
        return .{ .string = try runtime.allocator.dupe(u8, raw) };
    return .{ .number = @floatFromInt(integer) };
}

fn jsonToLua(runtime: *rt.Context, value: std.json.Value, preserve_keys: bool) !Value {
    return switch (value) {
        .null => .nil,
        .bool => |v| .{ .boolean = v },
        .integer => |v| .{ .number = @floatFromInt(v) },
        .float => |v| if (std.math.isFinite(v)) .{ .number = v } else error.InvalidJsonNumber,
        .number_string => |raw| blk: {
            const v = std.fmt.parseFloat(f64, raw) catch return error.InvalidJsonNumber;
            if (!std.math.isFinite(v)) return error.InvalidJsonNumber;
            break :blk .{ .number = v };
        },
        .string => |raw| .{ .string = try runtime.allocator.dupe(u8, raw) },
        .array => |array| blk: {
            const table = try runtime.newArrayTable(@intCast(array.items.len));
            for (array.items, 0..) |item, index| {
                const converted = try jsonToLua(runtime, item, preserve_keys);
                const key: f64 = @floatFromInt(if (preserve_keys) index else index + 1);
                try table.rawSet(runtime.allocator, .{ .number = key }, converted);
            }
            table.append_index = if (preserve_keys) @intCast(array.items.len) else @intCast(array.items.len + 1);
            break :blk .{ .table = table };
        },
        .object => |object| blk: {
            const table = try runtime.newTable();
            var it = object.iterator();
            while (it.next()) |entry| {
                const key = try jsonObjectKey(runtime, entry.key_ptr.*);
                try table.rawSet(runtime.allocator, key, try jsonToLua(runtime, entry.value_ptr.*, preserve_keys));
            }
            break :blk .{ .table = table };
        },
    };
}

fn fixJsonTrailingCommas(a: std.mem.Allocator, source: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    var copied: usize = 0;
    var scan: usize = 0;
    var changed = false;
    while (std.mem.indexOfScalarPos(u8, source, scan, ',')) |comma| {
        var p = comma + 1;
        while (p < source.len and (source[p] == ' ' or source[p] == '\t')) p += 1;

        // FormatJson pattern branch 1:
        // , [ \t]* [}\]] [^"\r\n]* ([\r\n]|$)
        if (p < source.len and (source[p] == '}' or source[p] == ']')) {
            var end = p + 1;
            var quote = false;
            while (end < source.len and source[end] != '\r' and source[end] != '\n') : (end += 1) {
                if (source[end] == '"') {
                    quote = true;
                    break;
                }
            }
            if (!quote) {
                if (end < source.len) end += 1;
                try out.appendSlice(a, source[copied..comma]);
                try out.appendSlice(a, source[comma + 1 .. end]);
                copied = end;
                scan = end;
                changed = true;
                continue;
            }
        }

        // FormatJson pattern branch 2:
        // , [ \t]* [\r\n] [ \t\r\n]* [}\]]
        p = comma + 1;
        while (p < source.len and (source[p] == ' ' or source[p] == '\t')) p += 1;
        if (p < source.len and (source[p] == '\r' or source[p] == '\n')) {
            p += 1;
            while (p < source.len and switch (source[p]) {
                ' ', '\t', '\r', '\n' => true,
                else => false,
            }) p += 1;
            if (p < source.len and (source[p] == '}' or source[p] == ']')) {
                try out.appendSlice(a, source[copied..comma]);
                try out.appendSlice(a, source[comma + 1 .. p + 1]);
                copied = p + 1;
                scan = copied;
                changed = true;
                continue;
            }
        }
        scan = comma + 1;
    }
    if (!changed) return null;
    try out.appendSlice(a, source[copied..]);
    return try out.toOwnedSlice(a);
}

pub fn jsonDecodeValue(runtime: *rt.Context, source: []const u8, flags: u32) !Value {
    var fixed: ?[]u8 = null;
    var parsed = std.json.parseFromSlice(std.json.Value, runtime.allocator, source, .{}) catch {
        if ((flags & json_try_fixing) == 0) return error.InvalidJson;
        fixed = try fixJsonTrailingCommas(runtime.allocator, source) orelse return error.InvalidJson;
        return jsonDecodeFixed(runtime, fixed.?, flags);
    };
    defer parsed.deinit();
    return jsonToLua(runtime, parsed.value, (flags & json_preserve_keys) != 0);
}

fn textJsonDecodeCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const flags = try jsonFlags(args);
    return one(runtime.allocator, try jsonDecodeValue(runtime, args[0].string, flags));
}

fn jsonDecodeFixed(runtime: *rt.Context, source: []const u8, flags: u32) !Value {
    var parsed = std.json.parseFromSlice(std.json.Value, runtime.allocator, source, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    return jsonToLua(runtime, parsed.value, (flags & json_preserve_keys) != 0);
}

fn jsonArrayIndex(key: Value) ?usize {
    if (key != .number) return null;
    const raw = key.number;
    if (!std.math.isFinite(raw) or raw != @trunc(raw)) return null;
    if (raw < 0 or raw > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(raw);
}

fn jsonSequenceIndex(key: Value, preserve_keys: bool) ?usize {
    if (jsonArrayIndex(key)) |index| return index;
    if (preserve_keys or key != .string or key.string.len == 0) return null;
    for (key.string) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseUnsigned(usize, key.string, 10) catch null;
}

const JsonSequence = struct {
    len: usize,
    first_index: usize,
};

fn jsonSequence(table: *rt.Table, preserve_keys: bool) ?JsonSequence {
    var count: usize = 0;
    var min_index: usize = 0;
    var max_index: usize = 0;
    var it = table.iterator();
    while (it.next()) |entry| {
        const index = jsonSequenceIndex(entry.key_ptr.*, preserve_keys) orelse return null;
        if (count == 0 or index < min_index) min_index = index;
        if (count == 0 or index > max_index) max_index = index;
        count += 1;
    }
    if (count == 0) return .{ .len = 0, .first_index = if (preserve_keys) 0 else 1 };
    if (min_index == 0 and max_index == count - 1)
        return .{ .len = count, .first_index = 0 };
    if (!preserve_keys and min_index == 1 and max_index == count)
        return .{ .len = count, .first_index = 1 };
    return null;
}

const JsonEncodeState = struct {
    runtime: *rt.Context,
    preserve_keys: bool,
    seen: std.AutoHashMapUnmanaged(*rt.Table, void) = .empty,
};

const JsonPair = struct { key: Value, value: Value };

fn collectJsonPairs(runtime: *rt.Context, table: *rt.Table, method: Value) !std.ArrayList(JsonPair) {
    var pairs: std.ArrayList(JsonPair) = .empty;
    errdefer pairs.deinit(runtime.allocator);
    const object = Value{ .table = table };
    const triple = try runtime.callValue(method, &.{object});
    defer rt.freeResults(triple);
    const iter = if (triple.len > 0) triple[0] else Value.nil;
    const state = if (triple.len > 1) triple[1] else Value.nil;
    var key = if (triple.len > 2) triple[2] else Value.nil;
    while (true) {
        const result = try runtime.callValue(iter, &.{ state, key });
        defer rt.freeResults(result);
        if (result.len == 0 or result[0] == .nil) break;
        key = result[0];
        try pairs.append(runtime.allocator, .{ .key = key, .value = if (result.len > 1) result[1] else .nil });
    }
    return pairs;
}

fn jsonPairSequence(a: std.mem.Allocator, pairs: []const JsonPair, preserve_keys: bool) !?JsonSequence {
    if (pairs.len == 0) return .{ .len = 0, .first_index = if (preserve_keys) 0 else 1 };
    var min_index: usize = 0;
    var max_index: usize = 0;
    for (pairs, 0..) |entry, i| {
        const index = jsonSequenceIndex(entry.key, preserve_keys) orelse return null;
        if (i == 0 or index < min_index) min_index = index;
        if (i == 0 or index > max_index) max_index = index;
    }
    const first_index: usize = if (min_index == 0 and max_index == pairs.len - 1)
        0
    else if (!preserve_keys and min_index == 1 and max_index == pairs.len)
        1
    else
        return null;
    const seen = try a.alloc(bool, pairs.len);
    defer a.free(seen);
    @memset(seen, false);
    for (pairs) |entry| {
        const index = jsonSequenceIndex(entry.key, preserve_keys).? - first_index;
        if (seen[index]) return null;
        seen[index] = true;
    }
    return .{ .len = pairs.len, .first_index = first_index };
}

fn jsonFromPairs(state: *JsonEncodeState, table: *rt.Table, method: Value) anyerror!std.json.Value {
    var pairs = try collectJsonPairs(state.runtime, table, method);
    defer pairs.deinit(state.runtime.allocator);
    if (try jsonPairSequence(state.runtime.allocator, pairs.items, state.preserve_keys)) |sequence| {
        var array = std.json.Array.init(state.runtime.allocator);
        errdefer array.deinit();
        for (0..sequence.len) |_| try array.append(.null);
        for (pairs.items) |entry| {
            const index = jsonSequenceIndex(entry.key, state.preserve_keys).? - sequence.first_index;
            array.items[index] = try luaToJson(state, entry.value);
        }
        return .{ .array = array };
    }
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(state.runtime.allocator);
    for (pairs.items) |entry| {
        const key = try luaTableKeyString(state, entry.key);
        const encoded = try luaToJson(state, entry.value);
        if (object.getPtr(key)) |existing| {
            deinitJsonTree(state.runtime.allocator, existing);
            existing.* = encoded;
        } else try object.put(state.runtime.allocator, key, encoded);
    }
    return .{ .object = object };
}

fn luaTableKeyString(state: *JsonEncodeState, key: Value) ![]const u8 {
    return switch (key) {
        .string => |text| text,
        .number => |number| blk: {
            if (!std.math.isFinite(number)) return error.InvalidJsonKey;
            break :blk try rt.numberToString(state.runtime.allocator, number);
        },
        else => error.InvalidJsonKey,
    };
}

fn luaToJson(state: *JsonEncodeState, value: Value) !std.json.Value {
    return switch (value) {
        .nil => .null,
        .boolean => |v| .{ .bool = v },
        .number => |v| blk: {
            if (!std.math.isFinite(v)) return error.InvalidJsonNumber;
            if (v == @trunc(v) and v >= @as(f64, @floatFromInt(std.math.minInt(i64))) and v <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
                break :blk .{ .integer = @intFromFloat(v) };
            break :blk .{ .float = v };
        },
        .string => |text| .{ .string = text },
        .callable => error.InvalidJsonValue,
        .table => |table| blk: {
            if (state.seen.contains(table)) return error.JsonRecursiveTable;
            try state.seen.put(state.runtime.allocator, table, {});
            defer _ = state.seen.remove(table);
            if (table.metatable) |mt| if (mt.rawGet(.{ .string = "__pairs" })) |method|
                break :blk try jsonFromPairs(state, table, method);

            if (jsonSequence(table, state.preserve_keys)) |sequence| {
                var array = std.json.Array.init(state.runtime.allocator);
                errdefer array.deinit();
                for (0..sequence.len) |_| try array.append(.null);
                var it = table.iterator();
                while (it.next()) |entry| {
                    const index = jsonSequenceIndex(entry.key_ptr.*, state.preserve_keys).? - sequence.first_index;
                    array.items[index] = try luaToJson(state, entry.value_ptr.*);
                }
                break :blk .{ .array = array };
            }

            var object: std.json.ObjectMap = .empty;
            errdefer object.deinit(state.runtime.allocator);
            var it = table.iterator();
            while (it.next()) |entry| {
                const key = try luaTableKeyString(state, entry.key_ptr.*);
                if (object.contains(key)) return error.DuplicateJsonKey;
                try object.put(state.runtime.allocator, key, try luaToJson(state, entry.value_ptr.*));
            }
            break :blk .{ .object = object };
        },
    };
}

fn deinitJsonTree(a: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .array => |*array| {
            for (array.items) |*item| deinitJsonTree(a, item);
            array.deinit();
        },
        .object => |*object| {
            var it = object.iterator();
            while (it.next()) |entry| deinitJsonTree(a, entry.value_ptr);
            object.deinit(a);
        },
        else => {},
    }
}

fn textJsonEncodeCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const value: Value = if (args.len == 0) .nil else args[0];
    const flags = try jsonFlags(args);
    var state = JsonEncodeState{ .runtime = runtime, .preserve_keys = (flags & json_preserve_keys) != 0 };
    defer state.seen.deinit(runtime.allocator);
    var encoded = try luaToJson(&state, value);
    defer deinitJsonTree(runtime.allocator, &encoded);
    const text = try std.json.Stringify.valueAlloc(runtime.allocator, encoded, .{
        .whitespace = if ((flags & json_pretty) != 0) .indent_4 else .minified,
    });
    return one(runtime.allocator, .{ .string = text });
}

fn appendCodepoint(out: *std.ArrayList(u8), a: std.mem.Allocator, value: u21) !bool {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(value, &buf) catch return false;
    try out.appendSlice(a, buf[0..len]);
    return true;
}

fn builtinEntity(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "gt")) return ">";
    if (std.mem.eql(u8, name, "lt")) return "<";
    if (std.mem.eql(u8, name, "amp")) return "&";
    if (std.mem.eql(u8, name, "quot")) return "\"";
    if (std.mem.eql(u8, name, "nbsp")) return "\u{a0}";
    return null;
}

fn textDecodeCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const source = args[0].string;
    const decode_named = args.len > 1 and args[1].truthy();
    if (std.mem.indexOfScalar(u8, source, '&') == null) return one(a, .{ .string = source });

    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (pos < source.len) {
        const amp = std.mem.indexOfScalarPos(u8, source, pos, '&') orelse {
            try out.appendSlice(a, source[pos..]);
            break;
        };
        try out.appendSlice(a, source[pos..amp]);
        var semi = amp + 1;
        while (semi < source.len and source[semi] != ';' and
            (std.ascii.isAlphanumeric(source[semi]) or source[semi] == '#')) : (semi += 1) {}
        if (semi >= source.len or source[semi] != ';') {
            try out.append(a, '&');
            pos = amp + 1;
            continue;
        }
        const body = source[amp + 1 .. semi];
        var replacement: ?[]const u8 = null;
        var numeric: ?u21 = null;
        if (std.mem.eql(u8, body, "#039")) {
            replacement = "'";
        } else if (body.len > 1 and body[0] == '#') {
            if (body.len > 2 and body[1] == 'x') {
                numeric = std.fmt.parseInt(u21, body[2..], 16) catch null;
            } else {
                numeric = std.fmt.parseInt(u21, body[1..], 10) catch null;
            }
        } else {
            replacement = builtinEntity(body);
            if (replacement == null and decode_named)
                replacement = html_entities.lookupHtmlNamedEntity(body);
        }

        if (replacement) |value| {
            try out.appendSlice(a, value);
            pos = semi + 1;
            continue;
        }
        if (numeric) |value| {
            if (try appendCodepoint(&out, a, value)) {
                pos = semi + 1;
                continue;
            }
        }
        try out.appendSlice(a, source[amp .. semi + 1]);
        pos = semi + 1;
    }
    return one(a, .{ .string = try out.toOwnedSlice(a) });
}

fn textTrimCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const chars = if (args.len > 1 and args[1] == .string) args[1].string else " \t\r\n\x0b\x0c";
    return one(a, .{ .string = std.mem.trim(u8, args[0].string, chars) });
}

fn ustringLength(host: *const Host, runtime: *rt.Context, text: []const u8) !f64 {
    const callable = host.ustring.rawGet(.{ .string = "len" }) orelse return error.NotImplemented;
    const result = try runtime.callValue(callable, &.{.{ .string = text }});
    defer rt.freeResults(result);
    if (result.len == 0 or result[0] != .number) return error.NumberExpected;
    return result[0].number;
}

fn ustringSub(host: *const Host, runtime: *rt.Context, text: []const u8, first: f64, last: ?f64) ![]const u8 {
    const callable = host.ustring.rawGet(.{ .string = "sub" }) orelse return error.NotImplemented;
    const result = if (last) |end|
        try runtime.callValue(callable, &.{ .{ .string = text }, .{ .number = first }, .{ .number = end } })
    else
        try runtime.callValue(callable, &.{ .{ .string = text }, .{ .number = first } });
    defer rt.freeResults(result);
    if (result.len == 0 or result[0] != .string) return error.StringExpected;
    return try runtime.allocator.dupe(u8, result[0].string);
}

fn textTruncateCall(host_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len < 2 or args[0] != .string) return error.StringExpected;
    const length = rt.toNumber(args[1]) orelse return error.NumberExpected;
    const host: *Host = @ptrCast(@alignCast(host_raw orelse return error.MissingTextHost));
    const source = args[0].string;
    const source_len = try ustringLength(host, runtime, source);
    if (source_len <= @abs(length)) return one(a, .{ .string = source });

    const ellipsis: []const u8 = if (args.len < 3 or args[2] == .nil or (args[2] == .boolean and !args[2].boolean))
        "..."
    else switch (args[2]) {
        .string => |value| value,
        .number => |value| try rt.numberToString(a, value),
        else => return error.StringExpected,
    };
    const adjust_length = args.len > 3 and args[3].truthy();
    const ellipsis_len: f64 = if (adjust_length) try ustringLength(host, runtime, ellipsis) else 0;

    const truncated = if (@abs(length) <= ellipsis_len)
        ellipsis
    else if (length > 0) blk: {
        const prefix = try ustringSub(host, runtime, source, 1, length - ellipsis_len);
        break :blk try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, ellipsis });
    } else blk: {
        const suffix = try ustringSub(host, runtime, source, length + ellipsis_len, null);
        break :blk try std.fmt.allocPrint(a, "{s}{s}", .{ ellipsis, suffix });
    };
    return one(a, .{ .string = if (try ustringLength(host, runtime, truncated) < source_len) truncated else source });
}

fn textListToTextCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const t = args[0].table;
    const n = t.rawLen();
    const separator = if (args.len > 1 and args[1] == .string) args[1].string else ", ";
    const conjunction = if (args.len > 2 and args[2] == .string) args[2].string else " and ";
    var pieces: std.ArrayList([]const u8) = .empty;
    var total: usize = 0;
    for (0..n) |i| {
        const value = t.rawGet(.{ .number = @floatFromInt(i + 1) }) orelse .nil;
        const text = try rt.toConcatString(a, value);
        try pieces.append(a, text);
        total += text.len;
        if (i + 1 < n) total += if (i + 2 == n) conjunction.len else separator.len;
    }
    const out = try a.alloc(u8, total);
    var pos: usize = 0;
    for (pieces.items, 0..) |piece, i| {
        @memcpy(out[pos .. pos + piece.len], piece);
        pos += piece.len;
        if (i + 1 < n) {
            const sep = if (i + 2 == n) conjunction else separator;
            @memcpy(out[pos .. pos + sep.len], sep);
            pos += sep.len;
        }
    }
    return one(a, .{ .string = out });
}

pub fn install(runtime: *rt.Context, mw: *rt.Table) !void {
    const ustring_value = mw.rawGet(.{ .string = "ustring" }) orelse return error.MissingUstringLibrary;
    if (ustring_value != .table) return error.MissingUstringLibrary;
    const host = try runtime.allocator.create(Host);
    host.* = .{ .ustring = ustring_value.table };
    const text = try runtime.newNativeNamespace(.text);
    try setNative(runtime, text, "split", host, textSplitCall);
    try setNative(runtime, text, "gsplit", host, textGsplitCall);
    try setNative(runtime, text, "trim", null, textTrimCall);
    try setNative(runtime, text, "unstrip", null, textUnstripCall);
    try setNative(runtime, text, "unstripNoWiki", null, textUnstripNoWikiCall);
    try setNative(runtime, text, "killMarkers", null, textKillMarkersCall);
    try setNative(runtime, text, "listToText", null, textListToTextCall);
    try setNative(runtime, text, "truncate", host, textTruncateCall);
    try setNative(runtime, text, "encode", null, textEncodeCall);
    try setNative(runtime, text, "decode", null, textDecodeCall);
    try setNative(runtime, text, "jsonEncode", null, textJsonEncodeCall);
    try setNative(runtime, text, "jsonDecode", null, textJsonDecodeCall);
    try setNative(runtime, text, "tag", null, textTagCall);
    try setNative(runtime, text, "nowiki", null, textNowikiCall);
    try text.rawSetNativeField(.text, "JSON_PRESERVE_KEYS", .{ .number = json_preserve_keys });
    try text.rawSetNativeField(.text, "JSON_TRY_FIXING", .{ .number = json_try_fixing });
    try text.rawSetNativeField(.text, "JSON_PRETTY", .{ .number = json_pretty });
    try mw.rawSetNativeField(.mw, "text", .{ .table = text });
}


test "mw.text JSON encode accepts zero-based arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();

    const value = try runtime.newTable();
    try value.rawSet(runtime.allocator, .{ .number = 0 }, .{ .string = "zero" });
    try value.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "one" });
    const encoded = try textJsonEncodeCall(null, &runtime, &.{.{ .table = value }});
    defer rt.freeResults(encoded);
    try std.testing.expectEqualStrings("[\"zero\",\"one\"]", encoded[0].string);
    const preserved = try textJsonEncodeCall(null, &runtime, &.{ .{ .table = value }, .{ .number = json_preserve_keys } });
    defer rt.freeResults(preserved);
    try std.testing.expectEqualStrings("[\"zero\",\"one\"]", preserved[0].string);
}

test "mw.text JSON encode reindexes digit-string keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();

    const value = try runtime.newTable();
    try value.rawSet(runtime.allocator, .{ .string = "1" }, .{ .string = "one" });
    try value.rawSet(runtime.allocator, .{ .string = "2" }, .{ .string = "two" });
    const encoded = try textJsonEncodeCall(null, &runtime, &.{.{ .table = value }});
    defer rt.freeResults(encoded);
    try std.testing.expectEqualStrings("[\"one\",\"two\"]", encoded[0].string);
}

test "mw.text JSON preserve keys keeps numeric object keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();

    const value = try runtime.newTable();
    try value.rawSet(runtime.allocator, .{ .number = 1 }, .{ .number = 1 });
    try value.rawSet(runtime.allocator, .{ .number = 2 }, .{ .string = "foo" });
    try value.rawSet(runtime.allocator, .{ .number = 3 }, .{ .boolean = true });
    try value.rawSet(runtime.allocator, .{ .number = 4 }, .{ .boolean = false });
    const encoded = try textJsonEncodeCall(null, &runtime, &.{ .{ .table = value }, .{ .number = json_preserve_keys } });
    defer rt.freeResults(encoded);
    try std.testing.expectEqualStrings("{\"1\":1,\"2\":\"foo\",\"3\":true,\"4\":false}", encoded[0].string);
}

fn jsonObjectPairsIter(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len > 1 and args[1] == .string and std.mem.eql(u8, args[1].string, "foo"))
        return one(runtime.allocator, .nil);
    const out = try std.heap.smp_allocator.alloc(Value, 2);
    out[0] = .{ .string = "foo" };
    out[1] = .nil;
    return out;
}

fn jsonArrayPairsIter(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return one(runtime.allocator, .nil);
    const next_index: usize = if (args.len < 2 or args[1] == .nil) 1 else blk: {
        if (args[1] != .number) return one(runtime.allocator, .nil);
        break :blk @as(usize, @intFromFloat(args[1].number)) + 1;
    };
    if (next_index > 4) return one(runtime.allocator, .nil);
    const out = try std.heap.smp_allocator.alloc(Value, 2);
    out[0] = .{ .number = @floatFromInt(next_index) };
    out[1] = args[0].table.rawGet(.{ .number = @floatFromInt(next_index) }) orelse .nil;
    return out;
}

fn jsonObjectPairs(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    out[0] = try runtime.newNative(null, jsonObjectPairsIter);
    out[1] = args[0];
    out[2] = .nil;
    return out;
}

fn jsonArrayPairs(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    out[0] = try runtime.newNative(null, jsonArrayPairsIter);
    out[1] = args[0];
    out[2] = .nil;
    return out;
}

test "mw.text JSON encode honors pairs metamethod" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();

    const object = try runtime.newTable();
    const object_mt = try runtime.newTable();
    try object_mt.rawSet(runtime.allocator, .{ .string = "__pairs" }, try runtime.newNative(null, jsonObjectPairs));
    object.metatable = object_mt;
    const object_encoded = try textJsonEncodeCall(null, &runtime, &.{.{ .table = object }});
    defer rt.freeResults(object_encoded);
    try std.testing.expectEqualStrings("{\"foo\":null}", object_encoded[0].string);

    const array = try runtime.newTable();
    try array.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "one" });
    try array.rawSet(runtime.allocator, .{ .number = 2 }, .{ .string = "two" });
    try array.rawSet(runtime.allocator, .{ .number = 4 }, .{ .string = "four" });
    const array_mt = try runtime.newTable();
    try array_mt.rawSet(runtime.allocator, .{ .string = "__pairs" }, try runtime.newNative(null, jsonArrayPairs));
    array.metatable = array_mt;
    const array_encoded = try textJsonEncodeCall(null, &runtime, &.{.{ .table = array }});
    defer rt.freeResults(array_encoded);
    try std.testing.expectEqualStrings("[\"one\",\"two\",null,\"four\"]", array_encoded[0].string);
}

fn tagPairsIter(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const key = if (args.len > 1) args[1] else Value.nil;
    const next: ?struct { []const u8, Value } = if (key == .nil)
        .{ "absent", .{ .boolean = false } }
    else if (key == .string and std.mem.eql(u8, key.string, "absent"))
        .{ "present", .{ .boolean = true } }
    else if (key == .string and std.mem.eql(u8, key.string, "present"))
        .{ "key", .{ .string = "value" } }
    else if (key == .string and std.mem.eql(u8, key.string, "key"))
        .{ "n", .{ .number = 42 } }
    else
        null;
    if (next) |item| {
        const out = try std.heap.smp_allocator.alloc(Value, 2);
        out[0] = .{ .string = item[0] };
        out[1] = item[1];
        return out;
    }
    return one(runtime.allocator, .nil);
}

fn tagPairs(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    out[0] = try runtime.newNative(null, tagPairsIter);
    out[1] = args[0];
    out[2] = .nil;
    return out;
}

test "mw.text tag honors pairs and ordinary table indexing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();

    const attrs = try runtime.newTable();
    const attrs_mt = try runtime.newTable();
    try attrs_mt.rawSet(runtime.allocator, .{ .string = "__pairs" }, try runtime.newNative(null, tagPairs));
    attrs.metatable = attrs_mt;

    const positional = try textTagCall(null, &runtime, &.{ .{ .string = "b" }, .{ .table = attrs } });
    defer rt.freeResults(positional);
    try std.testing.expectEqualStrings("<b present key=\"value\" n=\"42\">", positional[0].string);

    const fields = try runtime.newTable();
    try fields.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = "b" });
    try fields.rawSet(runtime.allocator, .{ .string = "attrs" }, .{ .table = attrs });
    try fields.rawSet(runtime.allocator, .{ .string = "content" }, .{ .string = "foo" });
    const spec = try runtime.newTable();
    const spec_mt = try runtime.newTable();
    try spec_mt.rawSet(runtime.allocator, .{ .string = "__index" }, .{ .table = fields });
    spec.metatable = spec_mt;
    const named = try textTagCall(null, &runtime, &.{.{ .table = spec }});
    defer rt.freeResults(named);
    try std.testing.expectEqualStrings("<b present key=\"value\" n=\"42\">foo</b>", named[0].string);
}
