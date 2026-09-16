const std = @import("std");
const rt = @import("zig_runtime");
const Value = rt.Value;

fn one(_: std.mem.Allocator, value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

fn two(_: std.mem.Allocator, first: Value, second: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 2);
    out[0] = first;
    out[1] = second;
    return out;
}

fn appendAnchorEncoded(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8) !void {
    var i: usize = 0;
    var pending_separator = false;
    while (i < source.len) {
        if (i + 1 < source.len and source[i] == '[' and source[i + 1] == '[') {
            if (std.mem.indexOfPos(u8, source, i + 2, "]]")) |close| {
                const inner = source[i + 2 .. close];
                const shown = if (std.mem.lastIndexOfScalar(u8, inner, '|')) |bar| inner[bar + 1 ..] else inner;
                try appendAnchorEncoded(out, a, shown);
                i = close + 2;
                continue;
            }
        }
        if (source[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, source, i + 1, '>')) |close| {
                i = close + 1;
                continue;
            }
        }
        if (source[i] == '&') {
            if (std.mem.startsWith(u8, source[i..], "&nbsp;")) {
                pending_separator = out.items.len != 0;
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, source[i..], "&amp;")) {
                if (pending_separator and out.items.len != 0 and out.items[out.items.len - 1] != '_') try out.append(a, '_');
                pending_separator = false;
                try out.appendSlice(a, "&amp;");
                i += 5;
                continue;
            }
        }
        const c = source[i];
        if (c == '_' or std.ascii.isWhitespace(c)) {
            pending_separator = out.items.len != 0;
            i += 1;
            continue;
        }
        if (pending_separator and out.items.len != 0 and out.items[out.items.len - 1] != '_') try out.append(a, '_');
        pending_separator = false;
        if (c == '%' and i + 2 < source.len and std.ascii.isHex(source[i + 1]) and std.ascii.isHex(source[i + 2])) {
            try out.appendSlice(a, "%25");
        } else switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '"' => try out.appendSlice(a, "&quot;"),
            '\'' => try out.appendSlice(a, "&#039;"),
            '[' => try out.appendSlice(a, "&#91;"),
            ']' => try out.appendSlice(a, "&#93;"),
            '{' => try out.appendSlice(a, "&#123;"),
            '}' => try out.appendSlice(a, "&#125;"),
            else => try out.append(a, c),
        }
        i += 1;
    }
}

pub const WikiUrlKind = enum { local, full, canonical };

fn appendWikiEncoded(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8) !void {
    for (source) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '!' or c == '$' or c == '(' or c == ')' or c == '*' or c == ',' or c == '.' or c == '/' or c == ':' or c == ';' or c == '@' or c == '~' or c == '_' or c == '-';
        if (safe) try out.append(a, c) else if (c == ' ') try out.append(a, '_') else try appendPercentByte(out, a, c);
    }
}

pub fn wikiEncodeAlloc(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendWikiEncoded(&out, a, source);
    return out.toOwnedSlice(a);
}

fn appendQueryEncoded(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8) !void {
    for (source) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '~' or c == '-';
        if (safe) try out.append(a, c) else if (c == ' ') try out.append(a, '+') else try appendPercentByte(out, a, c);
    }
}

fn appendAmpEscaped(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8, escaped: bool) !void {
    if (!escaped) return out.appendSlice(a, source);
    var start: usize = 0;
    for (source, 0..) |c, i| if (c == '&') {
        try out.appendSlice(a, source[start..i]);
        try out.appendSlice(a, "&amp;");
        start = i + 1;
    };
    try out.appendSlice(a, source[start..]);
}

pub fn buildWikiUrlRawQuery(a: std.mem.Allocator, raw_title: []const u8, query: ?[]const u8, kind: WikiUrlKind, escaped: bool, proto_override: ?[]const u8) ![]const u8 {
    const title = std.mem.trim(u8, raw_title, " \t\r\n");
    const hash = std.mem.indexOfScalar(u8, title, '#');
    const base_title = if (hash) |i| title[0..i] else title;
    const fragment = if (hash) |i| title[i + 1 ..] else "";
    var out: std.ArrayList(u8) = .empty;
    switch (kind) {
        .local => {},
        .full => {
            if (proto_override) |proto| {
                if (std.ascii.eqlIgnoreCase(proto, "http") or std.ascii.eqlIgnoreCase(proto, "https")) {
                    try out.appendSlice(a, proto);
                    try out.appendSlice(a, "://en.wiktionary.org");
                } else {
                    try out.appendSlice(a, "//en.wiktionary.org");
                }
            } else try out.appendSlice(a, "//en.wiktionary.org");
        },
        .canonical => try out.appendSlice(a, "https://en.wiktionary.org"),
    }
    if (query) |q| {
        try out.appendSlice(a, "/w/index.php?title=");
        try appendWikiEncoded(&out, a, base_title);
        if (q.len != 0) {
            try out.appendSlice(a, if (escaped) "&amp;" else "&");
            try appendAmpEscaped(&out, a, q, escaped);
        }
    } else {
        try out.appendSlice(a, "/wiki/");
        try appendWikiEncoded(&out, a, base_title);
    }
    if (fragment.len != 0) {
        try out.append(a, '#');
        try appendWikiEncoded(&out, a, fragment);
    }
    return out.toOwnedSlice(a);
}

pub fn buildTitleUrl(runtime: *rt.Context, raw_title: []const u8, query_value: Value, kind: WikiUrlKind, proto: ?[]const u8) ![]const u8 {
    if (kind != .full and proto != null) return error.InvalidTitleUrlProtocol;
    if (proto) |value| {
        if (!std.ascii.eqlIgnoreCase(value, "http") and
            !std.ascii.eqlIgnoreCase(value, "https") and
            !std.ascii.eqlIgnoreCase(value, "relative") and
            !std.ascii.eqlIgnoreCase(value, "canonical"))
            return error.InvalidTitleUrlProtocol;
    }
    const query = try buildQueryArgument(runtime, query_value);
    const effective_proto: ?[]const u8 = if (proto) |value|
        if (std.ascii.eqlIgnoreCase(value, "canonical")) "https" else if (std.ascii.eqlIgnoreCase(value, "relative")) null else value
    else
        null;
    if (kind != .local) return buildWikiUrlRawQuery(runtime.allocator, raw_title, query, kind, false, effective_proto);

    // MediaWiki Title::getLocalURL() does not include a title fragment.
    const hash = std.mem.indexOfScalar(u8, raw_title, '#');
    const without_fragment = if (hash) |at| raw_title[0..at] else raw_title;
    return buildWikiUrlRawQuery(runtime.allocator, without_fragment, query, kind, false, null);
}

fn queryScalarText(a: std.mem.Allocator, value: Value) !?[]const u8 {
    return switch (value) {
        .nil => null,
        .string => |s| s,
        .number => |n| try rt.numberToString(a, n),
        .boolean => |b| if (b) "1" else null,
        else => error.WikitextScalarExpected,
    };
}

pub fn buildQueryArgument(runtime: *rt.Context, value: Value) !?[]const u8 {
    if (value == .nil) return null;
    if (value == .string) return value.string;
    if (value != .table) return error.WikitextScalarExpected;
    var entries: std.ArrayList(struct { key: []const u8, value: Value }) = .empty;
    defer entries.deinit(runtime.allocator);
    var it = value.table.iterator();
    while (it.next()) |e| {
        const key = try queryScalarText(runtime.allocator, e.key_ptr.*) orelse continue;
        try entries.append(runtime.allocator, .{ .key = key, .value = e.value_ptr.* });
    }
    std.mem.sort(@TypeOf(entries.items[0]), entries.items, {}, struct {
        fn less(_: void, lhs: @TypeOf(entries.items[0]), rhs: @TypeOf(entries.items[0])) bool {
            return std.mem.order(u8, lhs.key, rhs.key) == .lt;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    for (entries.items, 0..) |entry, i| {
        if (i != 0) try out.append(runtime.allocator, '&');
        try appendQueryEncoded(&out, runtime.allocator, entry.key);
        if (entry.value == .boolean and !entry.value.boolean) continue;
        const text = try queryScalarText(runtime.allocator, entry.value) orelse continue;
        try out.append(runtime.allocator, '=');
        try appendQueryEncoded(&out, runtime.allocator, text);
    }
    const owned = try out.toOwnedSlice(runtime.allocator);
    return @as([]const u8, owned);
}

fn containsAny(source: []const u8, chars: []const u8) bool {
    return std.mem.indexOfAny(u8, source, chars) != null;
}

fn firstAny(source: []const u8, chars: []const u8) ?usize {
    return std.mem.indexOfAny(u8, source, chars);
}

fn percentDecodeAlloc(a: std.mem.Allocator, source: []const u8, plus_as_space: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        if (plus_as_space and source[i] == '+') {
            try out.append(a, ' ');
            i += 1;
            continue;
        }
        if (source[i] == '%' and i + 2 < source.len) {
            if (hexNibble(source[i + 1])) |hi| if (hexNibble(source[i + 2])) |lo| {
                try out.append(a, (hi << 4) | lo);
                i += 3;
                continue;
            };
        }
        try out.append(a, source[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn queryPut(runtime: *rt.Context, query: *rt.Table, key: []const u8, value: Value) !void {
    const k: Value = .{ .string = key };
    if (query.rawGet(k)) |existing| {
        if (!existing.truthy()) {
            try query.rawSet(runtime.allocator, k, value);
            return;
        }
        if (existing == .table) {
            try existing.table.rawSet(runtime.allocator, .{ .number = @floatFromInt(existing.table.rawLen() + 1) }, value);
            return;
        }
        const values = try runtime.newTable();
        try values.rawSet(runtime.allocator, .{ .number = 1 }, existing);
        try values.rawSet(runtime.allocator, .{ .number = 2 }, value);
        try query.rawSet(runtime.allocator, k, .{ .table = values });
        return;
    }
    try query.rawSet(runtime.allocator, k, value);
}

fn parseQueryAlloc(runtime: *rt.Context, source: []const u8) !*rt.Table {
    const query = try runtime.newTable();
    var pos: usize = 0;
    while (pos < source.len) {
        const amp = std.mem.indexOfScalarPos(u8, source, pos, '&') orelse source.len;
        const field = source[pos..amp];
        const eq = std.mem.indexOfScalar(u8, field, '=');
        const raw_key = field[0 .. eq orelse field.len];
        const key = try percentDecodeAlloc(runtime.allocator, raw_key, true);
        const value: Value = if (eq) |at|
            .{ .string = try percentDecodeAlloc(runtime.allocator, field[at + 1 ..], true) }
        else
            .{ .boolean = false };
        try queryPut(runtime, query, key, value);
        if (amp == source.len) break;
        pos = amp + 1;
    }
    return query;
}

fn setStringField(runtime: *rt.Context, object: *rt.Table, name: []const u8, value: ?[]const u8) !void {
    if (value) |text| try object.rawSet(runtime.allocator, .{ .string = name }, .{ .string = text });
}

fn parsePort(raw: []const u8) !f64 {
    if (raw.len == 0) return error.InvalidUriPort;
    const value = std.fmt.parseFloat(f64, raw) catch return error.InvalidUriPort;
    if (!std.math.isFinite(value)) return error.InvalidUriPort;
    return value;
}

fn parseAuthority(runtime: *rt.Context, object: *rt.Table, authority: []const u8) !void {
    var host_port = authority;
    if (std.mem.indexOfScalar(u8, authority, '@')) |at| {
        const user_info = authority[0..at];
        host_port = authority[at + 1 ..];
        if (std.mem.indexOfScalar(u8, user_info, ':')) |colon| {
            try setStringField(runtime, object, "user", user_info[0..colon]);
            try setStringField(runtime, object, "password", user_info[colon + 1 ..]);
        } else try setStringField(runtime, object, "user", user_info);
    }

    if (host_port.len != 0 and host_port[0] == '[') {
        if (std.mem.indexOfScalar(u8, host_port, ']')) |close| {
            if (close + 1 == host_port.len) {
                try setStringField(runtime, object, "host", host_port);
                return;
            }
            if (host_port[close + 1] == ':' and close + 2 <= host_port.len) {
                const port_text = host_port[close + 2 ..];
                if (port_text.len != 0) for (port_text) |c| if (!std.ascii.isDigit(c)) return error.InvalidUriPort;
                try setStringField(runtime, object, "host", host_port[0 .. close + 1]);
                try object.rawSet(runtime.allocator, .{ .string = "port" }, .{ .number = try parsePort(port_text) });
                return;
            }
        }
    }

    if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
        try setStringField(runtime, object, "host", host_port[0..colon]);
        try object.rawSet(runtime.allocator, .{ .string = "port" }, .{ .number = try parsePort(host_port[colon + 1 ..]) });
    } else try setStringField(runtime, object, "host", host_port);
}

fn parseRelative(runtime: *rt.Context, object: *rt.Table, relative: []const u8) !void {
    var end = relative.len;
    if (std.mem.indexOfScalar(u8, relative, '#')) |hash| {
        try setStringField(runtime, object, "fragment", relative[hash + 1 ..]);
        end = hash;
    }
    if (std.mem.indexOfScalar(u8, relative[0..end], '?')) |question| {
        try object.rawSet(runtime.allocator, .{ .string = "query" }, .{ .table = try parseQueryAlloc(runtime, relative[question + 1 .. end]) });
        end = question;
    }
    try setStringField(runtime, object, "path", relative[0..end]);
}

fn parseUriFields(runtime: *rt.Context, object: *rt.Table, source: []const u8) !void {
    var protocol: ?[]const u8 = null;
    var authority: ?[]const u8 = null;
    var relative = source;

    if (std.mem.indexOf(u8, source, "://")) |sep| {
        if (sep != 0 and !containsAny(source[0..sep], ":/?#")) {
            protocol = source[0..sep];
            const rest = source[sep + 3 ..];
            const authority_end = firstAny(rest, "/?#") orelse rest.len;
            authority = rest[0..authority_end];
            relative = rest[authority_end..];
        }
    }
    if (protocol == null and authority == null and std.mem.startsWith(u8, source, "//")) {
        const rest = source[2..];
        const authority_end = firstAny(rest, "/?#") orelse rest.len;
        authority = rest[0..authority_end];
        relative = rest[authority_end..];
    }
    if (protocol == null and authority == null) {
        if (firstAny(source, ":/?#")) |marker| if (source[marker] == ':' and marker != 0) {
            protocol = source[0..marker];
            relative = source[marker + 1 ..];
        };
    }

    try setStringField(runtime, object, "protocol", protocol);
    if (authority) |value| try parseAuthority(runtime, object, value);
    try parseRelative(runtime, object, relative);
}

fn truthyField(object: *rt.Table, name: []const u8) ?Value {
    const value = object.rawGet(.{ .string = name }) orelse return null;
    return if (value.truthy()) value else null;
}

fn validHost(host: []const u8) bool {
    if (!containsAny(host, ":/?#")) return true;
    if (host.len < 3 or host[0] != '[' or host[host.len - 1] != ']') return false;
    const inner = host[1 .. host.len - 1];
    return inner.len != 0 and !containsAny(inner, "/?#[]@");
}

fn validPath(path: []const u8, authority: bool, protocol: bool) bool {
    if (containsAny(path, "?#")) return false;
    if (authority) return path.len == 0 or path[0] == '/';
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return true;
    if (path[0] == '/') return path.len > 1 and path[1] != '/';
    if (protocol) return true;
    if (!containsAny(path, "/:")) return true;
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return false;
    return slash != 0 and !containsAny(path[0..slash], "/:");
}

fn appendValidationError(out: *std.ArrayList(u8), a: std.mem.Allocator, message: []const u8) !void {
    if (out.items.len != 0) try out.appendSlice(a, "; ");
    try out.appendSlice(a, message);
}

fn validationMessageAlloc(runtime: *rt.Context, object: *rt.Table) ![]const u8 {
    var errors: std.ArrayList(u8) = .empty;
    const a = runtime.allocator;

    const protocol_value = truthyField(object, "protocol");
    if (protocol_value) |value| {
        if (value != .string) try appendValidationError(&errors, a, ".protocol must be a string") else if (containsAny(value.string, ":/?#")) try appendValidationError(&errors, a, "invalid .protocol");
    }
    inline for (.{ "user", "password" }) |field| if (truthyField(object, field)) |value| {
        if (value != .string) try appendValidationError(&errors, a, ".user/password must be strings") else if (containsAny(value.string, ":@/?#")) try appendValidationError(&errors, a, "invalid .user/password");
    };
    if (truthyField(object, "host")) |value| {
        if (value != .string) try appendValidationError(&errors, a, ".host must be a string") else if (!validHost(value.string)) try appendValidationError(&errors, a, "invalid .host");
    }
    if (truthyField(object, "port")) |value| {
        if (value != .number or !std.math.isFinite(value.number) or @floor(value.number) != value.number)
            try appendValidationError(&errors, a, ".port must be an integer")
        else if (value.number < 1 or value.number > 65535)
            try appendValidationError(&errors, a, "invalid .port");
    }

    const authority = truthyField(object, "user") != null or truthyField(object, "password") != null or truthyField(object, "host") != null or truthyField(object, "port") != null;
    const path_value = truthyField(object, "path");
    if (path_value == null) {
        try appendValidationError(&errors, a, "missing .path");
    } else if (path_value.? != .string) {
        try appendValidationError(&errors, a, ".path must be a string");
    } else if (!validPath(path_value.?.string, authority, protocol_value != null)) {
        try appendValidationError(&errors, a, "invalid .path");
    }
    if (truthyField(object, "query")) |value| if (value != .table)
        try appendValidationError(&errors, a, ".query must be a table");
    if (truthyField(object, "fragment")) |value| if (value != .string)
        try appendValidationError(&errors, a, ".fragment must be a string");

    if (errors.items.len == 0) return "";
    return errors.toOwnedSlice(a);
}

const UriStringCtx = struct { url: []const u8 };

fn uriObjectToStringCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const a = runtime.allocator;
    const ctx: *UriStringCtx = @ptrCast(@alignCast(ctx_raw.?));
    return one(a, .{ .string = ctx.url });
}

fn makeUriObject(runtime: *rt.Context, url: []const u8) !Value {
    const object = try runtime.newTable();
    const mt = try runtime.newTable();
    const ctx = try runtime.allocator.create(UriStringCtx);
    ctx.* = .{ .url = url };
    try mt.rawSet(runtime.allocator, .{ .string = "__tostring" }, try runtime.newNative(ctx, uriObjectToStringCall));
    object.metatable = mt;
    try parseUriFields(runtime, object, url);
    if ((try validationMessageAlloc(runtime, object)).len != 0) return error.InvalidUri;
    return .{ .table = object };
}

fn uriNewCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] == .nil) return error.NotImplemented;
    if (args[0] != .string) return error.NotImplemented;
    return one(runtime.allocator, try makeUriObject(runtime, args[0].string));
}

fn uriValidateCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const message = try validationMessageAlloc(runtime, args[0].table);
    return two(runtime.allocator, .{ .boolean = message.len == 0 }, .{ .string = message });
}

fn uriUrlCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value, kind: WikiUrlKind) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const query = try buildQueryArgument(runtime, if (args.len > 1) args[1] else .nil);
    const url = try buildWikiUrlRawQuery(runtime.allocator, args[0].string, query, kind, false, null);
    return one(a, try makeUriObject(runtime, url));
}

fn uriFullUrlCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return uriUrlCall(raw, runtime, args, .full);
}

fn uriLocalUrlCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return uriUrlCall(raw, runtime, args, .local);
}

fn uriCanonicalUrlCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return uriUrlCall(raw, runtime, args, .canonical);
}

fn uriMode(args: []const Value) !enum { query, path, wiki } {
    if (args.len < 2 or args[1] == .nil) return .query;
    if (args[1] != .string) return error.StringExpected;
    const mode = args[1].string;
    if (std.ascii.eqlIgnoreCase(mode, "QUERY")) return .query;
    if (std.ascii.eqlIgnoreCase(mode, "PATH")) return .path;
    if (std.ascii.eqlIgnoreCase(mode, "WIKI")) return .wiki;
    return error.InvalidUriEncoding;
}

fn appendPercentByte(out: *std.ArrayList(u8), a: std.mem.Allocator, byte: u8) !void {
    const hex = "0123456789ABCDEF";
    try out.append(a, '%');
    try out.append(a, hex[byte >> 4]);
    try out.append(a, hex[byte & 0xf]);
}

fn uriEncodeCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const mode = try uriMode(args);
    var out: std.ArrayList(u8) = .empty;
    for (args[0].string) |c| {
        const raw_safe = std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '~' or c == '-';
        const wiki_safe = raw_safe or c == '!' or c == '$' or c == '(' or c == ')' or c == '*' or c == ',' or c == '/' or c == ':' or c == ';' or c == '@';
        if ((mode == .wiki and wiki_safe) or (mode != .wiki and raw_safe)) {
            try out.append(a, c);
        } else if (c == ' ') {
            if (mode == .query) try out.append(a, '+') else if (mode == .wiki) try out.append(a, '_') else try out.appendSlice(a, "%20");
        } else try appendPercentByte(&out, a, c);
    }
    return one(a, .{ .string = try out.toOwnedSlice(a) });
}

fn hexNibble(c: u8) ?u8 {
    return if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else null;
}

fn uriDecodeCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const mode = try uriMode(args);
    const source = args[0].string;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        if ((mode == .query and c == '+') or (mode == .wiki and c == '_')) {
            try out.append(a, ' ');
            i += 1;
            continue;
        }
        if (c == '%' and i + 2 < source.len) {
            if (hexNibble(source[i + 1])) |hi| if (hexNibble(source[i + 2])) |lo| {
                try out.append(a, (hi << 4) | lo);
                i += 3;
                continue;
            };
        }
        try out.append(a, c);
        i += 1;
    }
    return one(a, .{ .string = try out.toOwnedSlice(a) });
}

pub fn anchorEncodeAlloc(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendAnchorEncoded(&out, a, source);
    return out.toOwnedSlice(a);
}

fn uriAnchorEncodeCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    return one(a, .{ .string = try anchorEncodeAlloc(a, args[0].string) });
}

fn setNative(runtime: *rt.Context, table: *rt.Table, name: []const u8, comptime call: anytype) !void {
    try table.rawSet(runtime.allocator, .{ .string = name }, try runtime.newNative(null, call));
}

pub fn install(runtime: *rt.Context, mw: *rt.Table) !void {
    const uri = try runtime.newNativeNamespace(.uri);
    try setNative(runtime, uri, "fullUrl", uriFullUrlCall);
    try setNative(runtime, uri, "localUrl", uriLocalUrlCall);
    try setNative(runtime, uri, "canonicalUrl", uriCanonicalUrlCall);
    try setNative(runtime, uri, "encode", uriEncodeCall);
    try setNative(runtime, uri, "decode", uriDecodeCall);
    try setNative(runtime, uri, "anchorEncode", uriAnchorEncodeCall);
    try setNative(runtime, uri, "new", uriNewCall);
    try setNative(runtime, uri, "validate", uriValidateCall);
    try mw.rawSet(runtime.allocator, .{ .string = "uri" }, .{ .table = uri });
}

fn callField(runtime: *rt.Context, object: Value, name: []const u8, args: []const Value) ![]const Value {
    const callable = try runtime.getIndex(object, .{ .string = name });
    return runtime.callValue(callable, args);
}

test "AOT URI encode decode and anchors match MediaWiki modes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const mw = try runtime.newTable();
    try install(&runtime, mw);
    const uri = mw.rawGet(.{ .string = "uri" }).?.table;

    const query = try callField(&runtime, .{ .table = uri }, "encode", &.{ .{ .string = "a b&é" }, .{ .string = "QUERY" } });
    defer rt.freeResults(query);
    try std.testing.expectEqualStrings("a+b%26%C3%A9", query[0].string);
    const path = try callField(&runtime, .{ .table = uri }, "encode", &.{ .{ .string = "a b&é" }, .{ .string = "PATH" } });
    defer rt.freeResults(path);
    try std.testing.expectEqualStrings("a%20b%26%C3%A9", path[0].string);
    const decoded = try callField(&runtime, .{ .table = uri }, "decode", &.{ .{ .string = "a+b%26%C3%A9" }, .{ .string = "QUERY" } });
    defer rt.freeResults(decoded);
    try std.testing.expectEqualStrings("a b&é", decoded[0].string);
    const anchor = try callField(&runtime, .{ .table = uri }, "anchorEncode", &.{.{ .string = "[[foo|A B]] <b>x</b>&nbsp;C" }});
    defer rt.freeResults(anchor);
    try std.testing.expectEqualStrings("A_B_x_C", anchor[0].string);
    const escaped_anchor = try callField(&runtime, .{ .table = uri }, "anchorEncode", &.{.{ .string = "a%20b {c}" }});
    defer rt.freeResults(escaped_anchor);
    try std.testing.expectEqualStrings("a%2520b_&#123;c&#125;", escaped_anchor[0].string);
}

test "AOT URI builders sort query parameters and expose URI fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const mw = try runtime.newTable();
    try install(&runtime, mw);
    const uri = mw.rawGet(.{ .string = "uri" }).?.table;
    const query = try runtime.newTable();
    try query.rawSet(runtime.allocator, .{ .string = "z" }, .{ .number = 2 });
    try query.rawSet(runtime.allocator, .{ .string = "a" }, .{ .number = 1 });
    const built = try callField(&runtime, .{ .table = uri }, "canonicalUrl", &.{ .{ .string = "A B#Frag" }, .{ .table = query } });
    defer rt.freeResults(built);
    try std.testing.expect(built[0] == .table);
    const tostring = runtime.metamethod(built[0], "__tostring") orelse return error.MissingUriTostring;
    const rendered = try runtime.callValue(tostring, &.{built[0]});
    defer rt.freeResults(rendered);
    try std.testing.expectEqualStrings("https://en.wiktionary.org/w/index.php?title=A_B&a=1&z=2#Frag", rendered[0].string);
    try std.testing.expectEqualStrings("https", (try runtime.getIndex(built[0], .{ .string = "protocol" })).string);
    try std.testing.expectEqualStrings("en.wiktionary.org", (try runtime.getIndex(built[0], .{ .string = "host" })).string);
    try std.testing.expectEqualStrings("/w/index.php", (try runtime.getIndex(built[0], .{ .string = "path" })).string);
    try std.testing.expectEqualStrings("Frag", (try runtime.getIndex(built[0], .{ .string = "fragment" })).string);
}

test "AOT URI new and validate parse production URL fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const mw = try runtime.newTable();
    try install(&runtime, mw);
    const uri = mw.rawGet(.{ .string = "uri" }).?.table;

    const parsed = try callField(&runtime, .{ .table = uri }, "new", &.{.{ .string = "https://main.knesset.gov.il/apps/smartprotocol/session/123/456?itemid=7&bare&itemid=8#frag" }});
    defer rt.freeResults(parsed);
    try std.testing.expectEqualStrings("https", (try runtime.getIndex(parsed[0], .{ .string = "protocol" })).string);
    try std.testing.expectEqualStrings("main.knesset.gov.il", (try runtime.getIndex(parsed[0], .{ .string = "host" })).string);
    try std.testing.expectEqualStrings("/apps/smartprotocol/session/123/456", (try runtime.getIndex(parsed[0], .{ .string = "path" })).string);
    try std.testing.expectEqualStrings("frag", (try runtime.getIndex(parsed[0], .{ .string = "fragment" })).string);
    const parsed_query = (try runtime.getIndex(parsed[0], .{ .string = "query" })).table;
    try std.testing.expect(!(parsed_query.rawGet(.{ .string = "bare" }).?.boolean));
    const item_ids = parsed_query.rawGet(.{ .string = "itemid" }).?.table;
    try std.testing.expectEqualStrings("7", item_ids.rawGet(.{ .number = 1 }).?.string);
    try std.testing.expectEqualStrings("8", item_ids.rawGet(.{ .number = 2 }).?.string);

    const valid = try callField(&runtime, .{ .table = uri }, "validate", &.{parsed[0]});
    defer rt.freeResults(valid);
    try std.testing.expect(valid[0].boolean);
    try std.testing.expectEqualStrings("", valid[1].string);

    const ipv6 = try callField(&runtime, .{ .table = uri }, "new", &.{.{ .string = "http://[2001:db8::]:80" }});
    defer rt.freeResults(ipv6);
    try std.testing.expectEqualStrings("[2001:db8::]", (try runtime.getIndex(ipv6[0], .{ .string = "host" })).string);
    try std.testing.expectEqual(@as(f64, 80), (try runtime.getIndex(ipv6[0], .{ .string = "port" })).number);
}
