const std = @import("std");
const rt = @import("zig_runtime");
const shared_xml_decode = @import("shared_xml_decode");
const host_api = @import("host.zig");
const uri_lib = @import("uri.zig");
const Value = rt.Value;

const State = struct {
    metatable: ?*rt.Table = null,
    equals: ?Value = null,
    ustring: ?*rt.Table = null,
};

const BatchState = struct {
    title_state: *State,
    source: *rt.Table,
    namespace: ?Value,
    titles: ?*rt.Table = null,
};

fn one(value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

const namespace_lib = @import("namespaces.zig");
const namespaceSpecById = namespace_lib.byId;
const namespaceSpecByName = namespace_lib.byName;
const namespaceOf = namespace_lib.ofTitle;
fn isTitleSpace(cp: u21) bool {
    return cp == ' ' or cp == '_' or cp == 0x00a0 or cp == 0x1680 or cp == 0x180e or
        (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or
        cp == 0x202f or cp == 0x205f or cp == 0x3000;
}

fn isBidiOverride(cp: u21) bool {
    return cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e);
}

fn normalizeName(a: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending_space = false;
    var pos: usize = 0;
    while (pos < raw.len) {
        const len = std.unicode.utf8ByteSequenceLength(raw[pos]) catch return null;
        if (pos + len > raw.len) return null;
        const cp = std.unicode.utf8Decode(raw[pos .. pos + len]) catch return null;
        if (isBidiOverride(cp)) {
            pos += len;
            continue;
        }
        if (isTitleSpace(cp)) {
            pending_space = out.items.len != 0;
            pos += len;
            continue;
        }
        if (pending_space) try out.append(a, ' ');
        pending_space = false;
        try out.appendSlice(a, raw[pos .. pos + len]);
        pos += len;
    }
    return @as(?[]const u8, try out.toOwnedSlice(a));
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

fn titleForSpec(runtime: *rt.Context, spec: namespace_lib.Spec, text: []const u8) ![]const u8 {
    if (spec.id == 0) return text;
    return std.fmt.allocPrint(runtime.allocator, "{s}:{s}", .{ spec.name, text });
}

fn defaultContentModel(title: []const u8) []const u8 {
    const ns = namespaceOf(title);
    if (ns.id == 828) return "Scribunto";
    if (ns.id == 2 or ns.id == 8) {
        if (std.mem.endsWith(u8, ns.text, ".css")) return "css";
        if (std.mem.endsWith(u8, ns.text, ".js")) return "javascript";
        if (std.mem.endsWith(u8, ns.text, ".json")) return "json";
    }
    return "wikitext";
}

fn metaIndexCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 2 or args[0] != .table or args[1] != .string) return one(.nil);
    const state: *State = @ptrCast(@alignCast(raw orelse return error.MissingTitleState));
    const table = args[0].table;
    const key = args[1].string;
    const fragment = table.rawGet(.{ .string = "__fragment" }) orelse Value{ .string = "" };
    if (std.mem.eql(u8, key, "fragment")) return one(fragment);
    const prefixed = table.rawGet(.{ .string = "prefixedText" }) orelse return one(.nil);
    if (prefixed != .string or fragment != .string) return one(.nil);
    if (std.mem.eql(u8, key, "fullText")) {
        if (fragment.string.len == 0) return one(prefixed);
        return one(.{ .string = try std.fmt.allocPrint(runtime.allocator, "{s}#{s}", .{ prefixed.string, fragment.string }) });
    }
    if (std.mem.eql(u8, key, "file") or std.mem.eql(u8, key, "fileExists"))
        return error.NotImplemented;

    const ns = namespaceOf(prefixed.string);
    if (std.mem.eql(u8, key, "exists")) {
        const exists = try pageExists(runtime, prefixed.string);
        try table.rawSetNativeField(.title_value, "exists", .{ .boolean = exists });
        return one(.{ .boolean = exists });
    }
    const subject = namespace_lib.subjectSpec(ns.id);
    const is_talk = subject != null and subject.?.id != ns.id;
    if (std.mem.eql(u8, key, "isTalkPage")) return one(.{ .boolean = is_talk });
    if (std.mem.eql(u8, key, "subjectPageTitle")) {
        const spec = subject orelse return one(.nil);
        const title = try titleForSpec(runtime, spec, ns.text);
        return one(try makeTitleValue(runtime, state, title));
    }
    if (std.mem.eql(u8, key, "talkPageTitle")) {
        const spec = namespace_lib.talkSpec(ns.id) orelse return one(.nil);
        const title = try titleForSpec(runtime, spec, ns.text);
        return one(try makeTitleValue(runtime, state, title));
    }
    if (std.mem.eql(u8, key, "basePageTitle") or std.mem.eql(u8, key, "rootPageTitle")) {
        const spec = namespaceSpecById(ns.id) orelse return one(.nil);
        const text = if (!spec.has_subpages)
            ns.text
        else if (std.mem.eql(u8, key, "basePageTitle"))
            if (std.mem.lastIndexOfScalar(u8, ns.text, '/')) |slash| ns.text[0..slash] else ns.text
        else if (std.mem.indexOfScalar(u8, ns.text, '/')) |slash| ns.text[0..slash] else ns.text;
        const title = try titleForSpec(runtime, spec, text);
        return one(try makeTitleValue(runtime, state, title));
    }
    if (std.mem.eql(u8, key, "contentModel")) {
        const host = host_api.get(runtime);
        const model = if (host) |value|
            if (value.page_content_model) |get| try get(value.ctx, prefixed.string) else null
        else
            null;
        return one(.{ .string = model orelse defaultContentModel(prefixed.string) });
    }
    if (std.mem.eql(u8, key, "id")) {
        const host = host_api.get(runtime) orelse return one(.{ .number = 0 });
        const id = if (host.page_id) |get| try get(host.ctx, prefixed.string) else null;
        return one(.{ .number = @floatFromInt(id orelse 0) });
    }
    if (std.mem.eql(u8, key, "isRedirect") or std.mem.eql(u8, key, "redirectTarget")) {
        const host = host_api.get(runtime) orelse return one(if (std.mem.eql(u8, key, "isRedirect")) .{ .boolean = false } else .nil);
        const redirect = if (host.page_redirect) |get| try get(host.ctx, prefixed.string) else null;
        if (std.mem.eql(u8, key, "isRedirect")) return one(.{ .boolean = redirect != null });
        const target = redirect orelse return one(.nil);
        const canonical = try namespace_lib.canonicalizeTitle(runtime.allocator, target);
        return one(try makeTitleValue(runtime, state, canonical));
    }
    return one(.nil);
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
    try mt.rawSet(runtime.allocator, .{ .string = "__index" }, try runtime.newNative(state, metaIndexCall));
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

const TitleCtx = struct { title: []const u8, state: *State };

fn subPageTitleCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx: *TitleCtx = @ptrCast(@alignCast(raw orelse return error.MissingTitleContext));
    if (args.len < 2 or args[1] != .string) return one(.nil);
    const ns = namespaceOf(ctx.title);
    const text = try std.fmt.allocPrint(runtime.allocator, "{s}/{s}", .{ ns.text, args[1].string });
    const title = try titleForSpec(runtime, namespaceSpecById(ns.id) orelse return error.InvalidNamespace, text);
    return one(try makeTitleValue(runtime, ctx.state, title));
}

fn titleFullText(runtime: *rt.Context, table: *rt.Table) ![]const u8 {
    const prefixed = table.rawGet(.{ .string = "prefixedText" }) orelse return error.InvalidTitle;
    const fragment = table.rawGet(.{ .string = "__fragment" }) orelse Value{ .string = "" };
    if (prefixed != .string or fragment != .string) return error.InvalidTitle;
    if (fragment.string.len == 0) return prefixed.string;
    return std.fmt.allocPrint(runtime.allocator, "{s}#{s}", .{ prefixed.string, fragment.string });
}

fn titleUrlCall(runtime: *rt.Context, args: []const Value, kind: uri_lib.WikiUrlKind) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const query = if (args.len > 1) args[1] else Value.nil;
    const proto: ?[]const u8 = if (kind == .full and args.len > 2 and args[2] != .nil) blk: {
        if (args[2] != .string) return error.StringExpected;
        break :blk args[2].string;
    } else null;
    const full_text = try titleFullText(runtime, args[0].table);
    return one(.{ .string = try uri_lib.buildTitleUrl(runtime, full_text, query, kind, proto) });
}

fn fullUrlCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return titleUrlCall(runtime, args, .full);
}
fn localUrlCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return titleUrlCall(runtime, args, .local);
}
fn canonicalUrlCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return titleUrlCall(runtime, args, .canonical);
}

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
    const ns_spec = namespaceSpecById(ns.id) orelse return error.InvalidNamespace;
    const slash = if (ns_spec.has_subpages) std.mem.lastIndexOfScalar(u8, ns.text, '/') else null;
    const first_slash = if (ns_spec.has_subpages) std.mem.indexOfScalar(u8, ns.text, '/') else null;
    try table.rawSetNativeField(.title_value, "text", .{ .string = ns.text });
    try table.rawSetNativeField(.title_value, "prefixedText", .{ .string = base_title });
    try table.rawSetNativeField(.title_value, "__fragment", .{ .string = fragment });
    try table.rawSetNativeField(.title_value, "namespace", .{ .number = @floatFromInt(ns.id) });
    try table.rawSetNativeField(.title_value, "nsText", .{ .string = ns.name });
    try table.rawSetNativeField(.title_value, "subpageText", .{ .string = if (slash) |pos| ns.text[pos + 1 ..] else ns.text });
    try table.rawSetNativeField(.title_value, "baseText", .{ .string = if (slash) |pos| ns.text[0..pos] else ns.text });
    try table.rawSetNativeField(.title_value, "rootText", .{ .string = if (first_slash) |pos| ns.text[0..pos] else ns.text });
    try table.rawSetNativeField(.title_value, "isSubpage", .{ .boolean = slash != null });
    try table.rawSetNativeField(.title_value, "interwiki", .{ .string = "" });
    try table.rawSetNativeField(.title_value, "isExternal", .{ .boolean = false });
    try table.rawSetNativeField(.title_value, "isLocal", .{ .boolean = true });
    table.metatable = try ensureMetatable(runtime, state);
    const ctx = try runtime.allocator.create(TitleCtx);
    ctx.* = .{ .title = base_title, .state = state };
    try table.rawSetNativeField(.title_value, "getContent", try runtime.newNative(ctx, getContentCall));
    try table.rawSetNativeField(.title_value, "fullUrl", try runtime.newNative(null, fullUrlCall));
    try table.rawSetNativeField(.title_value, "localUrl", try runtime.newNative(null, localUrlCall));
    try table.rawSetNativeField(.title_value, "canonicalUrl", try runtime.newNative(null, canonicalUrlCall));
    try table.rawSet(runtime.allocator, .{ .string = "subPageTitle" }, try runtime.newNative(ctx, subPageTitleCall));
    return .{ .table = table };
}
fn normalizedNewText(runtime: *rt.Context, state: *State, raw: []const u8) ![]const u8 {
    const decoded = try shared_xml_decode.decodeSinglePassAlloc(runtime.allocator, raw);
    if (std.mem.eql(u8, decoded, raw)) return decoded;
    const ustring = state.ustring orelse return decoded;
    const to_nfc = ustring.rawGet(.{ .string = "toNFC" }) orelse return decoded;
    const result = try runtime.callValue(to_nfc, &.{.{ .string = decoded }});
    defer rt.freeResults(result);
    if (result.len == 0 or result[0] != .string) return error.StringExpected;
    return result[0].string;
}

fn namespaceArgument(value: ?Value, required: bool) !namespace_lib.Spec {
    const actual = value orelse return if (required) error.InvalidNamespace else namespaceSpecById(0).?;
    if (actual == .nil) return if (required) error.InvalidNamespace else namespaceSpecById(0).?;
    const spec = switch (actual) {
        .number => |number| blk: {
            if (!std.math.isFinite(number) or number != @trunc(number) or
                number < @as(f64, @floatFromInt(std.math.minInt(i32))) or number > @as(f64, @floatFromInt(std.math.maxInt(i32))))
                break :blk null;
            break :blk namespaceSpecById(@intFromFloat(number));
        },
        .string => |name| namespaceSpecByName(name),
        else => null,
    };
    return spec orelse error.InvalidNamespace;
}

fn legalTitleAscii(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        ' ', '%', '!', '"', '$', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '=', '?', '@', '\\', '^', '_', '`', '~' => true,
        else => false,
    };
}

fn hasPercentEscape(text: []const u8) bool {
    if (text.len < 3) return false;
    for (text[0 .. text.len - 2], 0..) |c, i|
        if (c == '%' and std.ascii.isHex(text[i + 1]) and std.ascii.isHex(text[i + 2])) return true;
    return false;
}

fn hasNamedCharacterReference(text: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, pos, '&')) |amp| {
        var i = amp + 1;
        var any = false;
        while (i < text.len and text[i] != ';') : (i += 1) {
            const c = text[i];
            if (!(std.ascii.isAlphanumeric(c) or c >= 0x80)) break;
            any = true;
        }
        if (any and i < text.len and text[i] == ';') return true;
        pos = amp + 1;
    }
    return false;
}

fn validTitleBody(spec: namespace_lib.Spec, text_with_fragment: []const u8) bool {
    const hash = std.mem.indexOfScalar(u8, text_with_fragment, '#');
    const text = if (hash) |at| text_with_fragment[0..at] else text_with_fragment;
    if (text.len == 0) return spec.id == 0 and hash != null;
    if (text[0] == ':') return false;
    if (spec.id == 1) if (std.mem.indexOfScalar(u8, text, ':')) |colon|
        if (colon != 0 and namespaceSpecByName(std.mem.trim(u8, text[0..colon], " ")) != null) return false;
    for (text) |c| if (c < 0x80 and !legalTitleAscii(c)) return false;
    if (hasPercentEscape(text) or hasNamedCharacterReference(text)) return false;
    if (std.mem.indexOf(u8, text, "~~~") != null) return false;
    if (std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, "..") or
        std.mem.startsWith(u8, text, "./") or std.mem.startsWith(u8, text, "../") or
        std.mem.indexOf(u8, text, "/./") != null or std.mem.indexOf(u8, text, "/../") != null or
        std.mem.endsWith(u8, text, "/.") or std.mem.endsWith(u8, text, "/..")) return false;
    const max_len: usize = if (spec.id == -1) 512 else 255;
    return text.len <= max_len;
}

fn titleForNamespace(a: std.mem.Allocator, spec: namespace_lib.Spec, text: []const u8) !?[]const u8 {
    if (!validTitleBody(spec, text)) return null;
    if (spec.id == 0) return text;
    return @as(?[]const u8, try std.fmt.allocPrint(a, "{s}:{s}", .{ spec.name, text }));
}

const InterwikiDisposition = enum { none, current_wiki, external };

fn interwikiDisposition(runtime: *rt.Context, prefix: []const u8) !InterwikiDisposition {
    const host = host_api.get(runtime) orelse return error.NotImplemented;
    const get = host.site_interwiki_map orelse return error.NotImplemented;
    for (try get(host.ctx)) |row| {
        if (!std.ascii.eqlIgnoreCase(row.prefix, prefix)) continue;
        return if (row.is_current_wiki) .current_wiki else .external;
    }
    return .none;
}

fn titleWithNamespace(runtime: *rt.Context, state: *State, text_raw: []const u8, namespace: ?Value, force_namespace: bool, decode_entities: bool) !?[]const u8 {
    const a = runtime.allocator;
    const source = if (decode_entities) try normalizedNewText(runtime, state, text_raw) else text_raw;
    var text = (try normalizeName(a, source)) orelse return null;
    if (text.len == 0) return null;
    var default_spec = try namespaceArgument(namespace, force_namespace);
    if (force_namespace) return titleForNamespace(a, default_spec, text);

    if (text[0] == ':') {
        default_spec = namespaceSpecById(0).?;
        text = std.mem.trimStart(u8, text[1..], " ");
        if (text.len == 0) return null;
    }
    if (std.mem.indexOfScalar(u8, text, ':')) |colon| if (colon != 0) {
        const prefix = std.mem.trim(u8, text[0..colon], " ");
        const body = std.mem.trimStart(u8, text[colon + 1 ..], " ");
        if (namespaceSpecByName(prefix)) |explicit_spec|
            return titleForNamespace(a, explicit_spec, body);
        switch (try interwikiDisposition(runtime, prefix)) {
            .none => {},
            .current_wiki => {
                if (body.len == 0) return error.NotImplemented;
                return titleWithNamespace(runtime, state, body, null, false, false);
            },
            .external => return error.NotImplemented,
        }
    };
    return titleForNamespace(a, default_spec, text);
}

fn buildBatchTitles(runtime: *rt.Context, batch: *BatchState) !*rt.Table {
    if (batch.titles) |titles| return titles;
    const titles = try runtime.newTable();
    const n = batch.source.rawLen();
    for (0..n) |i| {
        const index: f64 = @floatFromInt(i + 1);
        const value = batch.source.rawGet(.{ .number = index }) orelse continue;
        if (value != .string) return error.StringExpected;
        const title = try titleWithNamespace(runtime, batch.title_state, value.string, batch.namespace, false, true) orelse continue;
        try titles.rawSet(runtime.allocator, .{ .number = index }, try makeTitleValue(runtime, batch.title_state, title));
    }
    batch.titles = titles;
    return titles;
}

fn batchLookupExistenceCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const batch: *BatchState = @ptrCast(@alignCast(raw orelse return error.MissingTitleBatchState));
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const titles = try buildBatchTitles(runtime, batch);
    const n = batch.source.rawLen();
    for (0..n) |i| {
        const title = titles.rawGet(.{ .number = @floatFromInt(i + 1) }) orelse continue;
        if (title != .table) continue;
        const prefixed = title.table.rawGet(.{ .string = "prefixedText" }) orelse continue;
        if (prefixed != .string or namespaceOf(prefixed.string).id == -2) continue;
        _ = try runtime.getIndex(title, .{ .string = "exists" });
    }
    return one(args[0]);
}

fn batchGetTitlesCall(raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const batch: *BatchState = @ptrCast(@alignCast(raw orelse return error.MissingTitleBatchState));
    return one(.{ .table = try buildBatchTitles(runtime, batch) });
}

fn newBatchCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const state: *State = @ptrCast(@alignCast(raw orelse return error.MissingTitleState));
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const namespace: ?Value = if (args.len > 1 and args[1] != .nil) args[1] else null;
    const n = args[0].table.rawLen();
    for (0..n) |i| {
        const value = args[0].table.rawGet(.{ .number = @floatFromInt(i + 1) }) orelse continue;
        if (value != .string) return error.StringExpected;
    }
    const batch_state = try runtime.allocator.create(BatchState);
    batch_state.* = .{ .title_state = state, .source = args[0].table, .namespace = namespace };
    const batch = try runtime.newTable();
    try batch.rawSet(runtime.allocator, .{ .string = "lookupExistence" }, try runtime.newNative(batch_state, batchLookupExistenceCall));
    try batch.rawSet(runtime.allocator, .{ .string = "getTitles" }, try runtime.newNative(batch_state, batchGetTitlesCall));
    return one(.{ .table = batch });
}

fn newCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const state: *State = @ptrCast(@alignCast(raw orelse return error.MissingTitleState));
    if (args.len == 0 or args[0] != .string) return one(.nil);
    const title = try titleWithNamespace(runtime, state, args[0].string, if (args.len > 1) args[1] else null, false, true) orelse return one(.nil);
    return one(try makeTitleValue(runtime, state, title));
}

fn makeCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const state: *State = @ptrCast(@alignCast(raw orelse return error.MissingTitleState));
    if (args.len < 2 or args[1] != .string) return one(.nil);
    const fragment: []const u8 = if (args.len > 2 and args[2] != .nil) blk: {
        if (args[2] != .string) return error.StringExpected;
        break :blk args[2].string;
    } else "";
    if (args.len > 3 and args[3] != .nil) {
        if (args[3] != .string) return error.StringExpected;
        if (args[3].string.len != 0) return error.NotImplemented;
    }
    const title = try titleWithNamespace(runtime, state, args[1].string, args[0], true, false) orelse return one(.nil);
    if (fragment.len == 0) return one(try makeTitleValue(runtime, state, title));
    const with_fragment = try std.fmt.allocPrint(runtime.allocator, "{s}#{s}", .{ title, fragment });
    return one(try makeTitleValue(runtime, state, with_fragment));
}
fn currentCall(raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const state: *State = @ptrCast(@alignCast(raw orelse return error.MissingTitleState));
    const host = host_api.get(runtime) orelse return error.MissingScribuntoHost;
    if (host.current_title.len == 0) return error.MissingCurrentTitle;
    return one(try makeTitleValue(runtime, state, host.current_title));
}

pub fn install(runtime: *rt.Context, mw: *rt.Table) !void {
    const state = try runtime.allocator.create(State);
    const ustring: ?*rt.Table = if (mw.rawGet(.{ .string = "ustring" })) |value| switch (value) {
        .table => |table| table,
        else => null,
    } else null;
    state.* = .{ .ustring = ustring };
    _ = try ensureMetatable(runtime, state);
    const title = try runtime.newNativeNamespace(.title);
    try title.rawSetNativeField(.title, "equals", state.equals.?);
    try title.rawSetNativeField(.title, "compare", try runtime.newNative(null, compareCall));
    try title.rawSetNativeField(.title, "new", try runtime.newNative(state, newCall));
    try title.rawSetNativeField(.title, "makeTitle", try runtime.newNative(state, makeCall));
    try title.rawSetNativeField(.title, "getCurrentTitle", try runtime.newNative(state, currentCall));
    try title.rawSetNativeField(.title, "newBatch", try runtime.newNative(state, newBatchCall));
    try mw.rawSetNativeField(.mw, "title", .{ .table = title });
}

fn testPageExists(_: ?*anyopaque, title: []const u8) !bool {
    return std.mem.eql(u8, title, "Template:Foo/Sub") or std.mem.eql(u8, title, "Template:Alias");
}

fn testPageRedirect(_: ?*anyopaque, title: []const u8) !?[]const u8 {
    return if (std.mem.eql(u8, title, "Template:Alias")) "Template:Foo/Sub" else null;
}

fn testPageId(_: ?*anyopaque, title: []const u8) !?u64 {
    if (std.mem.eql(u8, title, "Template:Foo/Sub")) return 77;
    if (std.mem.eql(u8, title, "Template:Alias")) return 78;
    return null;
}

fn testPageContentModel(_: ?*anyopaque, title: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, title, "Template:Foo/Sub") or std.mem.eql(u8, title, "Template:Alias")) return "wikitext";
    return null;
}

const test_interwiki_rows = [_]host_api.InterwikiRow{
    .{ .prefix = "w", .url = "https://example.test/$1", .is_local = false, .is_current_wiki = false, .is_protocol_relative = false },
    .{ .prefix = "self", .url = "https://local.test/$1", .is_local = true, .is_current_wiki = true, .is_protocol_relative = false },
};

fn testInterwikiMap(_: ?*anyopaque) ![]const host_api.InterwikiRow {
    return &test_interwiki_rows;
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
    var host = host_api.Host{ .current_title = "Template:Foo/Sub", .page_exists = testPageExists, .page_content = testPageContent, .page_redirect = testPageRedirect, .page_id = testPageId, .page_content_model = testPageContentModel };
    host_api.set(&runtime, &host);
    const mw = try runtime.newNativeNamespace(.mw);
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
    const base_page = try runtime.getIndex(title, .{ .string = "basePageTitle" });
    try std.testing.expectEqualStrings("Template:Foo", (try runtime.getIndex(base_page, .{ .string = "prefixedText" })).string);
    const root_page = try runtime.getIndex(title, .{ .string = "rootPageTitle" });
    try std.testing.expectEqualStrings("Template:Foo", (try runtime.getIndex(root_page, .{ .string = "prefixedText" })).string);
    const sub_page_fn = try runtime.getIndex(title, .{ .string = "subPageTitle" });
    const sub_page = try runtime.callValue(sub_page_fn, &.{ title, .{ .string = "Next" } });
    defer rt.freeResults(sub_page);
    try std.testing.expectEqualStrings("Template:Foo/Sub/Next", (try runtime.getIndex(sub_page[0], .{ .string = "prefixedText" })).string);
    try std.testing.expect((try runtime.getIndex(title, .{ .string = "exists" })).boolean);
    try std.testing.expectEqual(@as(f64, 77), (try runtime.getIndex(title, .{ .string = "id" })).number);
    try std.testing.expectEqualStrings("wikitext", (try runtime.getIndex(title, .{ .string = "contentModel" })).string);
    try std.testing.expectEqualStrings(" frag ment", (try runtime.getIndex(title, .{ .string = "fragment" })).string);
    try std.testing.expectEqualStrings("Template:Foo/Sub# frag ment", (try runtime.getIndex(title, .{ .string = "fullText" })).string);
    const full_url = try callField(&runtime, title, "fullUrl", &.{ title, .nil, .{ .string = "https" } });
    defer rt.freeResults(full_url);
    try std.testing.expectEqualStrings("https://en.wiktionary.org/wiki/Template:Foo/Sub#_frag_ment", full_url[0].string);
    const query = try runtime.newTable();
    try query.rawSet(runtime.allocator, .{ .string = "action" }, .{ .string = "test" });
    const queried_url = try callField(&runtime, title, "fullUrl", &.{ title, .{ .table = query } });
    defer rt.freeResults(queried_url);
    try std.testing.expectEqualStrings("//en.wiktionary.org/w/index.php?title=Template:Foo/Sub&action=test#_frag_ment", queried_url[0].string);
    const local_url = try callField(&runtime, title, "localUrl", &.{title});
    defer rt.freeResults(local_url);
    try std.testing.expectEqualStrings("/wiki/Template:Foo/Sub", local_url[0].string);
    const canonical_url = try callField(&runtime, title, "canonicalUrl", &.{title});
    defer rt.freeResults(canonical_url);
    try std.testing.expectEqualStrings("https://en.wiktionary.org/wiki/Template:Foo/Sub#_frag_ment", canonical_url[0].string);
    try std.testing.expect(!(try runtime.getIndex(title, .{ .string = "isTalkPage" })).boolean);
    const talk = try runtime.getIndex(title, .{ .string = "talkPageTitle" });
    try std.testing.expect(talk == .table);
    try std.testing.expectEqualStrings("Template talk:Foo/Sub", (try runtime.getIndex(talk, .{ .string = "prefixedText" })).string);
    const subject = try runtime.getIndex(talk, .{ .string = "subjectPageTitle" });
    try std.testing.expect(subject == .table);
    try std.testing.expectEqualStrings("Template:Foo/Sub", (try runtime.getIndex(subject, .{ .string = "prefixedText" })).string);
    try std.testing.expect((try runtime.getIndex(talk, .{ .string = "isTalkPage" })).boolean);

    const redirect_made = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = "Template:Alias" }});
    defer rt.freeResults(redirect_made);
    try std.testing.expectEqual(@as(f64, 78), (try runtime.getIndex(redirect_made[0], .{ .string = "id" })).number);
    try std.testing.expect((try runtime.getIndex(redirect_made[0], .{ .string = "isRedirect" })).boolean);
    const redirect_target = try runtime.getIndex(redirect_made[0], .{ .string = "redirectTarget" });
    try std.testing.expect(redirect_target == .table);
    try std.testing.expectEqualStrings("Template:Foo/Sub", (try runtime.getIndex(redirect_target, .{ .string = "prefixedText" })).string);
    try std.testing.expect(!(try runtime.getIndex(title, .{ .string = "isRedirect" })).boolean);

    const alias_made = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = "WT:Sandbox_page" }});
    defer rt.freeResults(alias_made);
    try std.testing.expectEqualStrings("Wiktionary:Sandbox page", (try runtime.getIndex(alias_made[0], .{ .string = "prefixedText" })).string);

    const batch_input = try runtime.newTable();
    try batch_input.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "Foo/Sub" });
    try batch_input.rawSet(runtime.allocator, .{ .number = 2 }, .{ .string = "Missing" });
    const batch = try callField(&runtime, .{ .table = title_lib }, "newBatch", &.{ .{ .table = batch_input }, .{ .number = 10 } });
    defer rt.freeResults(batch);
    const looked_up = try callField(&runtime, batch[0], "lookupExistence", &.{batch[0]});
    defer rt.freeResults(looked_up);
    try std.testing.expect(looked_up[0] == .table and looked_up[0].table == batch[0].table);
    const batch_titles = try callField(&runtime, batch[0], "getTitles", &.{batch[0]});
    defer rt.freeResults(batch_titles);
    const batch_first = batch_titles[0].table.rawGet(.{ .number = 1 }).?;
    const batch_second = batch_titles[0].table.rawGet(.{ .number = 2 }).?;
    try std.testing.expect((try runtime.getIndex(batch_first, .{ .string = "exists" })).boolean);
    try std.testing.expect(!(try runtime.getIndex(batch_second, .{ .string = "exists" })).boolean);
    try std.testing.expectEqualStrings("Template:Foo/Sub", (try runtime.getIndex(batch_first, .{ .string = "prefixedText" })).string);

    const content = try callField(&runtime, title, "getContent", &.{title});
    defer rt.freeResults(content);
    try std.testing.expectEqualStrings("template body", content[0].string);
    try runtime.setIndex(title, .{ .string = "fragment" }, .{ .string = " next_part " });
    try std.testing.expectEqualStrings(" next part", (try runtime.getIndex(title, .{ .string = "fragment" })).string);
}

test "AOT title subpage fields respect namespace settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const mw = try runtime.newNativeNamespace(.mw);
    try install(&runtime, mw);
    const title_lib = mw.rawGet(.{ .string = "title" }).?.table;
    const made = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = "foo/bar" }});
    defer rt.freeResults(made);
    const title = made[0];
    try std.testing.expect(!(try runtime.getIndex(title, .{ .string = "isSubpage" })).boolean);
    try std.testing.expectEqualStrings("foo/bar", (try runtime.getIndex(title, .{ .string = "baseText" })).string);
    try std.testing.expectEqualStrings("foo/bar", (try runtime.getIndex(title, .{ .string = "rootText" })).string);
    try std.testing.expectEqualStrings("foo/bar", (try runtime.getIndex(title, .{ .string = "subpageText" })).string);
    const base = try runtime.getIndex(title, .{ .string = "basePageTitle" });
    try std.testing.expectEqualStrings("foo/bar", (try runtime.getIndex(base, .{ .string = "prefixedText" })).string);
    try std.testing.expectEqualStrings("wikitext", (try runtime.getIndex(title, .{ .string = "contentModel" })).string);
    const missing_module = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = "Module:Missing" }});
    defer rt.freeResults(missing_module);
    try std.testing.expectEqualStrings("Scribunto", (try runtime.getIndex(missing_module[0], .{ .string = "contentModel" })).string);
    const missing_css = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = "User:Example/common.css" }});
    defer rt.freeResults(missing_css);
    try std.testing.expectEqualStrings("css", (try runtime.getIndex(missing_css[0], .{ .string = "contentModel" })).string);

    const file_title = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = "File:Example.svg" }});
    defer rt.freeResults(file_title);
    inline for (.{ "file", "fileExists" }) |field| {
        try std.testing.expectError(error.AotCallFailed, runtime.getIndex(file_title[0], .{ .string = field }));
        try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
        runtime.clearAotErrorName();
    }
}

test "AOT title constructors and current title use the live host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .current_title = "Module:Current/Sub" };
    host_api.set(&runtime, &host);
    const mw = try runtime.newNativeNamespace(.mw);
    try install(&runtime, mw);
    const title_lib = mw.rawGet(.{ .string = "title" }).?.table;

    const current = try callField(&runtime, .{ .table = title_lib }, "getCurrentTitle", &.{});
    defer rt.freeResults(current);
    try std.testing.expectEqualStrings("Current/Sub", (try runtime.getIndex(current[0], .{ .string = "text" })).string);
    try std.testing.expectEqual(@as(f64, 828), (try runtime.getIndex(current[0], .{ .string = "namespace" })).number);

    const made = try callField(&runtime, .{ .table = title_lib }, "makeTitle", &.{ .{ .number = 10 }, .{ .string = "Thing" } });
    defer rt.freeResults(made);
    const fragmented = try callField(&runtime, .{ .table = title_lib }, "makeTitle", &.{ .{ .string = "Wiktionary" }, .{ .string = "Word of the day/Archive/2026/September" }, .{ .string = "17" } });
    defer rt.freeResults(fragmented);
    try std.testing.expectEqualStrings("Wiktionary:Word of the day/Archive/2026/September", (try runtime.getIndex(fragmented[0], .{ .string = "prefixedText" })).string);
    try std.testing.expectEqualStrings("17", (try runtime.getIndex(fragmented[0], .{ .string = "fragment" })).string);
    try std.testing.expectEqualStrings("Wiktionary:Word of the day/Archive/2026/September#17", (try runtime.getIndex(fragmented[0], .{ .string = "fullText" })).string);
    const normalized_fragment = try callField(&runtime, .{ .table = title_lib }, "makeTitle", &.{ .{ .number = 4 }, .{ .string = "Page" }, .{ .string = "  frag__frag  " } });
    defer rt.freeResults(normalized_fragment);
    try std.testing.expectEqualStrings(" frag frag", (try runtime.getIndex(normalized_fragment[0], .{ .string = "fragment" })).string);
    const made2 = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = "Template:Thing" }});
    defer rt.freeResults(made2);
    try std.testing.expectEqualStrings("Template:Thing", (try runtime.getIndex(made[0], .{ .string = "prefixedText" })).string);
    const decoded_new = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = "Foo&amp;Bar" }});
    defer rt.freeResults(decoded_new);
    try std.testing.expectEqualStrings("Foo&Bar", (try runtime.getIndex(decoded_new[0], .{ .string = "prefixedText" })).string);
    const decoded_namespace = try callField(&runtime, .{ .table = title_lib }, "new", &.{ .{ .string = "Module&#58;Thing" }, .{ .number = 10 } });
    defer rt.freeResults(decoded_namespace);
    try std.testing.expectEqualStrings("Module:Thing", (try runtime.getIndex(decoded_namespace[0], .{ .string = "prefixedText" })).string);
    const undecoded_make = try callField(&runtime, .{ .table = title_lib }, "makeTitle", &.{ .{ .number = 0 }, .{ .string = "Foo&amp;Bar" } });
    defer rt.freeResults(undecoded_make);
    try std.testing.expect(undecoded_make[0] == .nil);
    const one_pass = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = "Foo&amp;amp;Bar" }});
    defer rt.freeResults(one_pass);
    try std.testing.expect(one_pass[0] == .nil);
    const collapsed = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = "  foo__  bar  " }});
    defer rt.freeResults(collapsed);
    try std.testing.expectEqualStrings("foo bar", (try runtime.getIndex(collapsed[0], .{ .string = "prefixedText" })).string);
    const initial_colon = try callField(&runtime, .{ .table = title_lib }, "new", &.{ .{ .string = ":foo" }, .{ .number = 10 } });
    defer rt.freeResults(initial_colon);
    try std.testing.expectEqualStrings("foo", (try runtime.getIndex(initial_colon[0], .{ .string = "prefixedText" })).string);
    const spaced_namespace = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = "Template : Foo" }});
    defer rt.freeResults(spaced_namespace);
    try std.testing.expectEqualStrings("Template:Foo", (try runtime.getIndex(spaced_namespace[0], .{ .string = "prefixedText" })).string);
    inline for (&.{ "foo[bar", "foo%20bar", "foo/../bar", "foo~~~bar", "Template:" }) |invalid| {
        const value = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = invalid }});
        defer rt.freeResults(value);
        try std.testing.expect(value[0] == .nil);
    }

    const defaulted_explicit = try callField(&runtime, .{ .table = title_lib }, "new", &.{ .{ .string = "Module:Thing" }, .{ .number = 10 } });
    defer rt.freeResults(defaulted_explicit);
    try std.testing.expectEqualStrings("Module:Thing", (try runtime.getIndex(defaulted_explicit[0], .{ .string = "prefixedText" })).string);
    const forced_explicit = try callField(&runtime, .{ .table = title_lib }, "makeTitle", &.{ .{ .number = 10 }, .{ .string = "Module:Thing" } });
    defer rt.freeResults(forced_explicit);
    try std.testing.expectEqualStrings("Template:Module:Thing", (try runtime.getIndex(forced_explicit[0], .{ .string = "prefixedText" })).string);
    const make_fn = title_lib.rawGet(.{ .string = "makeTitle" }).?;
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(make_fn, &.{ .{ .number = 0 }, .{ .string = "Thing" }, .{ .number = 1 } }));
    try std.testing.expectEqualStrings("StringExpected", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(make_fn, &.{ .{ .number = 0 }, .{ .string = "Thing" }, .nil, .{ .string = "w" } }));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
    const new_fn = title_lib.rawGet(.{ .string = "new" }).?;
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(new_fn, &.{ .{ .string = "Thing" }, .{ .string = "not-a-namespace" } }));
    try std.testing.expectEqualStrings("InvalidNamespace", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(new_fn, &.{.{ .string = "w:Thing" }}));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
    host.site_interwiki_map = testInterwikiMap;
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(new_fn, &.{.{ .string = "w:Thing" }}));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
    const local_interwiki = try runtime.callValue(new_fn, &.{.{ .string = "self:Template:Thing" }});
    defer rt.freeResults(local_interwiki);
    try std.testing.expectEqualStrings("Template:Thing", (try runtime.getIndex(local_interwiki[0], .{ .string = "prefixedText" })).string);
    try std.testing.expect(!(try runtime.getIndex(local_interwiki[0], .{ .string = "isExternal" })).boolean);
    try std.testing.expect((try runtime.getIndex(local_interwiki[0], .{ .string = "isLocal" })).boolean);
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
