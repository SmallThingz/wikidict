const std = @import("std");
const rt = @import("zig_runtime");
const Value = rt.Value;

const Host = struct {
    ustring: *rt.Table,
};

fn one(_: std.mem.Allocator, value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

fn setNative(runtime: *rt.Context, table: *rt.Table, name: []const u8, host: ?*anyopaque, call: rt.NativeFn) !void {
    try table.rawSet(runtime.allocator, .{ .string = name }, try runtime.newNative(host, call));
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
    if (std.mem.indexOfScalar(u8, source, 0x7f) != null) return error.NotImplemented;
    return one(runtime.allocator, .{ .string = source });
}

fn textUnstripNoWikiCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return textUnstripCall(null, runtime, args);
}

fn textTrimCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const chars = if (args.len > 1 and args[1] == .string) args[1].string else " \t\r\n\x0b\x0c";
    return one(a, .{ .string = std.mem.trim(u8, args[0].string, chars) });
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
    try setNative(runtime, text, "listToText", null, textListToTextCall);
    try setNative(runtime, text, "nowiki", null, textNowikiCall);
    try mw.rawSet(runtime.allocator, .{ .string = "text" }, .{ .table = text });
}
