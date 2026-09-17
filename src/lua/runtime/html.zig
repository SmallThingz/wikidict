const std = @import("std");
const rt = @import("zig_runtime");
const Value = rt.Value;

const Pair = struct { name: []const u8, value: []const u8 };
const Attr = struct { name: []const u8, value: Value };
const Style = union(enum) { property: Pair, raw: []const u8 };
const Child = union(enum) { text: []const u8, node: *Node };

const Html = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMapUnmanaged(*rt.Table, *Node) = .empty,
};

const Node = struct {
    html: *Html,
    table: *rt.Table,
    parent: ?*Node,
    tag_name: ?[]const u8,
    self_closing: bool = false,
    children: std.ArrayList(Child) = .empty,
    attrs: std.ArrayList(Attr) = .empty,
    styles: std.ArrayList(Style) = .empty,
};

fn one(_: std.mem.Allocator, value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}
fn scalarText(a: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        .number => |n| try rt.numberToString(a, n),
        else => error.HtmlScalarExpected,
    };
}

fn validAttributeName(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_' or first == ':')) return false;
    for (name[1..]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == ':' or ch == '-')) return false;
    }
    return true;
}

fn attrIndex(node: *Node, name: []const u8) ?usize {
    for (node.attrs.items, 0..) |attr, i| if (std.mem.eql(u8, attr.name, name)) return i;
    return null;
}

fn setAttr(node: *Node, name: []const u8, value: ?Value) !void {
    if (!validAttributeName(name)) return error.InvalidHtmlAttributeName;
    if (std.mem.eql(u8, name, "style")) {
        node.styles.clearRetainingCapacity();
        if (value) |raw| try node.styles.append(node.html.allocator, .{ .raw = try scalarText(node.html.allocator, raw) });
        return;
    }
    if (attrIndex(node, name)) |i| {
        if (value) |raw| node.attrs.items[i].value = raw else _ = node.attrs.orderedRemove(i);
        return;
    }
    if (value) |raw| try node.attrs.append(node.html.allocator, .{ .name = name, .value = raw });
}

fn setStyleProperty(node: *Node, name: []const u8, value: ?[]const u8) !void {
    for (node.styles.items, 0..) |*style, i| switch (style.*) {
        .raw => {},
        .property => |*pair| {
            if (!std.mem.eql(u8, pair.name, name)) continue;
            if (value) |raw| pair.value = raw else _ = node.styles.orderedRemove(i);
            return;
        },
    };
    if (value) |raw| try node.styles.append(node.html.allocator, .{ .property = .{ .name = name, .value = raw } });
}

fn returnSelf(node: *Node, a: std.mem.Allocator) ![]const Value {
    return one(a, .{ .table = node.table });
}

fn forEachPair(node: *Node, runtime: *rt.Context, table: *rt.Table, comptime visitor: anytype) !void {
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
            try visitor(node, key, if (result.len > 1) result[1] else Value.nil);
        }
        return;
    };
    var it = table.iterator();
    while (it.next()) |entry| try visitor(node, entry.key_ptr.*, entry.value_ptr.*);
}

fn applyAttrPair(node: *Node, key: Value, value: Value) !void {
    if (key != .string or (value != .string and value != .number)) return error.HtmlAttributeTableExpected;
    try setAttr(node, key.string, value);
}

fn applyCssPair(node: *Node, key: Value, value: Value) !void {
    const name = try scalarText(node.html.allocator, key);
    const text = try scalarText(node.html.allocator, value);
    try setStyleProperty(node, name, text);
}

fn selfClosingTag(name: []const u8) bool {
    inline for (.{
        "area", "base", "br",    "col",    "command", "embed", "hr", "img", "input", "keygen",
        "link", "meta", "param", "source", "track",   "wbr",
    }) |tag| if (std.mem.eql(u8, name, tag)) return true;
    return false;
}

fn validTagName(name: []const u8) bool {
    if (name.len == 0) return true;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
    return true;
}

fn forcedSelfClosing(value: ?Value) !bool {
    const option = value orelse return false;
    if (option == .nil) return false;
    if (option != .table) return error.HtmlOptionsExpected;
    const raw = option.table.rawGet(.{ .string = "selfClosing" }) orelse return false;
    return raw.truthy();
}

fn newNode(html: *Html, runtime: *rt.Context, parent: ?*Node, tag_name: ?[]const u8) !*Node {
    if (tag_name) |name| if (!validTagName(name)) return error.InvalidHtmlTag;
    const node = try html.allocator.create(Node);
    const table = try runtime.newNativeNamespace(.html_node);
    node.* = .{
        .html = html,
        .table = table,
        .parent = parent,
        .tag_name = if (tag_name) |name| if (name.len == 0) null else name else null,
        .self_closing = if (tag_name) |name| selfClosingTag(name) else false,
    };
    try html.nodes.put(html.allocator, table, node);
    return node;
}
fn setNative(node: *Node, runtime: *rt.Context, name: []const u8, comptime call: anytype) !void {
    try node.table.rawSet(node.html.allocator, .{ .string = name }, try runtime.newNative(node, call));
}

fn installNodeMethods(node: *Node, runtime: *rt.Context) !void {
    try setNative(node, runtime, "tag", tagCall);
    try setNative(node, runtime, "done", doneCall);
    try setNative(node, runtime, "allDone", allDoneCall);
    try setNative(node, runtime, "wikitext", wikitextCall);
    try setNative(node, runtime, "node", nodeCall);
    try setNative(node, runtime, "css", cssCall);
    try setNative(node, runtime, "cssText", cssTextCall);
    try setNative(node, runtime, "addClass", addClassCall);
    try setNative(node, runtime, "attr", attrCall);
    try setNative(node, runtime, "getAttr", getAttrCall);
    try setNative(node, runtime, "newline", newlineCall);
    const mt = try runtime.newTable();
    try mt.rawSet(node.html.allocator, .{ .string = "__tostring" }, try runtime.newNative(node, tostringCall));
    node.table.metatable = mt;
}

fn createCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const html: *Html = @ptrCast(@alignCast(ctx_raw.?));
    const tag_name: ?[]const u8 = if (args.len == 0 or args[0] == .nil) null else if (args[0] == .string) args[0].string else return error.HtmlTagExpected;
    const node = try newNode(html, runtime, null, tag_name);
    node.self_closing = node.self_closing or try forcedSelfClosing(if (args.len > 1) args[1] else null);
    try installNodeMethods(node, runtime);
    return one(a, .{ .table = node.table });
}

fn appendChild(node: *Node, child: Child) !void {
    if (node.self_closing) return error.HtmlSelfClosingHasChildren;
    try node.children.append(node.html.allocator, child);
}

fn tagCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len < 2 or args[1] != .string) return error.HtmlTagExpected;
    if (node.self_closing) return error.HtmlSelfClosingHasChildren;
    const child = try newNode(node.html, runtime, node, args[1].string);
    child.self_closing = child.self_closing or try forcedSelfClosing(if (args.len > 2) args[2] else null);
    try installNodeMethods(child, runtime);
    try appendChild(node, .{ .node = child });
    return one(a, .{ .table = child.table });
}

fn doneCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    return one(a, .{ .table = if (node.parent) |parent| parent.table else node.table });
}

fn allDoneCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const a = runtime.allocator;
    var node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    while (node.parent) |parent| node = parent;
    return one(a, .{ .table = node.table });
}

fn wikitextCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    for (args[1..]) |value| {
        if (value == .nil) break;
        try appendChild(node, .{ .text = try scalarText(node.html.allocator, value) });
    }
    return returnSelf(node, a);
}
fn nodeCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len < 2 or args[1] == .nil) return returnSelf(node, a);
    switch (args[1]) {
        .string, .number => try appendChild(node, .{ .text = try scalarText(node.html.allocator, args[1]) }),
        .boolean => |value| try appendChild(node, .{ .text = if (value) "true" else "false" }),
        .table => |table| {
            const child = node.html.nodes.get(table) orelse return error.HtmlNodeExpected;
            try appendChild(node, .{ .node = child });
        },
        else => return error.HtmlNodeExpected,
    }
    return returnSelf(node, a);
}

fn cssCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len < 2) return error.HtmlCssNameExpected;
    if (args[1] == .table) {
        if (args.len > 2 and args[2] != .nil) return error.HtmlCssTableValue;
        try forEachPair(node, runtime, args[1].table, applyCssPair);
        return returnSelf(node, a);
    }
    const name = try scalarText(node.html.allocator, args[1]);
    const value = if (args.len < 3 or args[2] == .nil) null else try scalarText(node.html.allocator, args[2]);
    try setStyleProperty(node, name, value);
    return returnSelf(node, a);
}

fn cssTextCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len >= 2 and args[1] != .nil) {
        try node.styles.append(node.html.allocator, .{ .raw = try scalarText(node.html.allocator, args[1]) });
    }
    return returnSelf(node, a);
}
fn addClassCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len < 2 or args[1] == .nil) return returnSelf(node, a);
    const class = try scalarText(node.html.allocator, args[1]);
    if (attrIndex(node, "class")) |i| {
        const previous = try scalarText(node.html.allocator, node.attrs.items[i].value);
        node.attrs.items[i].value = .{ .string = try std.fmt.allocPrint(node.html.allocator, "{s} {s}", .{ previous, class }) };
    } else {
        try setAttr(node, "class", args[1]);
    }
    return returnSelf(node, a);
}

fn attrCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len < 2) return error.HtmlAttributeNameExpected;
    if (args[1] == .table) {
        if (args.len > 2 and args[2] != .nil) return error.HtmlAttributeTableValue;
        try forEachPair(node, runtime, args[1].table, applyAttrPair);
        return returnSelf(node, a);
    }
    if (args[1] != .string) return error.HtmlAttributeNameExpected;
    const value: ?Value = if (args.len < 3 or args[2] == .nil) null else switch (args[2]) {
        .string, .number => args[2],
        else => return error.HtmlAttributeValueExpected,
    };
    try setAttr(node, args[1].string, value);
    return returnSelf(node, a);
}

fn getAttrCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len < 2 or args[1] != .string) return error.HtmlAttributeNameExpected;
    const value: Value = if (attrIndex(node, args[1].string)) |i| node.attrs.items[i].value else .nil;
    return one(runtime.allocator, value);
}
fn newlineCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    try appendChild(node, .{ .text = "\n" });
    return returnSelf(node, a);
}

fn appendEscapedAttribute(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        else => try out.append(a, c),
    };
}

fn appendAttribute(out: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, value: Value) !void {
    try out.append(a, ' ');
    try out.appendSlice(a, name);
    try out.appendSlice(a, "=\"");
    try appendEscapedAttribute(out, a, try scalarText(a, value));
    try out.append(a, '"');
}
fn appendCssEncoded(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    var pos: usize = 0;
    while (pos < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return error.InvalidUtf8;
        if (pos + len > text.len) return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(text[pos .. pos + len]) catch return error.InvalidUtf8;
        if ((cp >= 32 and cp <= 57) or (cp >= 60 and cp <= 127)) {
            try out.appendSlice(a, text[pos .. pos + len]);
        } else {
            var buffer: [16]u8 = undefined;
            try out.appendSlice(a, try std.fmt.bufPrint(&buffer, "\\{X} ", .{cp}));
        }
        pos += len;
    }
}

fn appendStyleValue(node: *Node, out: *std.ArrayList(u8)) !void {
    const a = node.html.allocator;
    for (node.styles.items, 0..) |style, i| {
        if (i != 0) try out.append(a, ';');
        switch (style) {
            .raw => |text| try out.appendSlice(a, text),
            .property => |pair| {
                try appendCssEncoded(out, a, pair.name);
                try out.append(a, ':');
                try appendCssEncoded(out, a, pair.value);
            },
        }
    }
}

fn renderNode(node: *Node, out: *std.ArrayList(u8)) !void {
    const a = node.html.allocator;
    if (node.tag_name) |tag| {
        try out.append(a, '<');
        try out.appendSlice(a, tag);
        for (node.attrs.items) |attr| try appendAttribute(out, a, attr.name, attr.value);
        if (node.styles.items.len != 0) {
            var styles: std.ArrayList(u8) = .empty;
            try appendStyleValue(node, &styles);
            try appendAttribute(out, a, "style", .{ .string = styles.items });
        }
        if (node.self_closing) {
            try out.appendSlice(a, " />");
            return;
        }
        try out.append(a, '>');
    }
    for (node.children.items) |child| switch (child) {
        .text => |text| try out.appendSlice(a, text),
        .node => |nested| try renderNode(nested, out),
    };
    if (node.tag_name) |tag| {
        try out.appendSlice(a, "</");
        try out.appendSlice(a, tag);
        try out.append(a, '>');
    }
}

fn tostringCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    var out: std.ArrayList(u8) = .empty;
    try renderNode(node, &out);
    return one(a, .{ .string = try out.toOwnedSlice(node.html.allocator) });
}
pub fn install(runtime: *rt.Context, mw: *rt.Table) !void {
    const a = runtime.allocator;
    const html_ctx = try a.create(Html);
    html_ctx.* = .{ .allocator = a };
    const html = try runtime.newNativeNamespace(.html);
    try html.rawSetNativeField(.html, "create", try runtime.newNative(html_ctx, createCall));
    try mw.rawSetNativeField(.mw, "html", .{ .table = html });
}

fn orderedPairsIter(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const key = if (args.len > 1) args[1] else Value.nil;
    if (key == .nil) {
        const out = try std.heap.smp_allocator.alloc(Value, 2);
        out[0] = .{ .string = "ab" };
        out[1] = .{ .string = "cd" };
        return out;
    }
    if (key == .string and std.mem.eql(u8, key.string, "ab")) {
        const out = try std.heap.smp_allocator.alloc(Value, 2);
        out[0] = .{ .string = "foo" };
        out[1] = .{ .string = "bar" };
        return out;
    }
    return one(runtime.allocator, .nil);
}

fn orderedPairs(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    out[0] = try runtime.newNative(null, orderedPairsIter);
    out[1] = args[0];
    out[2] = .nil;
    return out;
}

test "html table setters honor pairs metamethod" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 0);
    defer runtime.deinit();
    const html = try a.create(Html);
    html.* = .{ .allocator = a };

    const values = try runtime.newTable();
    try values.rawSet(a, .{ .string = "foo" }, .{ .string = "bar" });
    try values.rawSet(a, .{ .string = "ab" }, .{ .string = "cd" });
    const mt = try runtime.newTable();
    try mt.rawSet(a, .{ .string = "__pairs" }, try runtime.newNative(null, orderedPairs));
    values.metatable = mt;

    const attr_root = try newNode(html, &runtime, null, "div");
    try installNodeMethods(attr_root, &runtime);
    const attr_result = try attrCall(attr_root, &runtime, &.{ .{ .table = attr_root.table }, .{ .table = values } });
    defer rt.freeResults(attr_result);
    var out: std.ArrayList(u8) = .empty;
    try renderNode(attr_root, &out);
    try std.testing.expectEqualStrings("<div ab=\"cd\" foo=\"bar\"></div>", out.items);

    const css_root = try newNode(html, &runtime, null, "div");
    try installNodeMethods(css_root, &runtime);
    const css_result = try cssCall(css_root, &runtime, &.{ .{ .table = css_root.table }, .{ .table = values } });
    defer rt.freeResults(css_result);
    out.items.len = 0;
    try renderNode(css_root, &out);
    try std.testing.expectEqualStrings("<div style=\"ab:cd;foo:bar\"></div>", out.items);
}

test "html builder chaining and serialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 0);
    defer runtime.deinit();
    const html = try a.create(Html);
    html.* = .{ .allocator = a };
    const root = try newNode(html, &runtime, null, "div");
    try installNodeMethods(root, &runtime);
    try setAttr(root, "class", .{ .string = "box" });
    try setStyleProperty(root, "width", "2px");
    try setAttr(root, "title", .{ .string = "a&b" });
    const child = try newNode(html, &runtime, root, "span");
    try installNodeMethods(child, &runtime);
    try child.children.append(a, .{ .text = "wiki" });
    try root.children.append(a, .{ .node = child });
    var out: std.ArrayList(u8) = .empty;
    try renderNode(root, &out);
    try std.testing.expectEqualStrings("<div class=\"box\" title=\"a&amp;b\" style=\"width:2px\"><span>wiki</span></div>", out.items);
}

test "html builder matches MediaWiki attribute class and style semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 0);
    defer runtime.deinit();
    const html = try a.create(Html);
    html.* = .{ .allocator = a };
    const root = try newNode(html, &runtime, null, "div");
    try installNodeMethods(root, &runtime);
    const self = Value{ .table = root.table };

    const attr_result = try attrCall(root, &runtime, &.{ self, .{ .string = "town" }, .{ .string = "Berlin" } });
    defer rt.freeResults(attr_result);
    const getter = try runtime.getIndex(self, .{ .string = "getAttr" });
    const got = try runtime.callValue(getter, &.{ self, .{ .string = "town" } });
    defer rt.freeResults(got);
    try std.testing.expectEqualStrings("Berlin", got[0].string);
    const missing = try runtime.callValue(getter, &.{ self, .{ .string = "missing" } });
    defer rt.freeResults(missing);
    try std.testing.expect(missing[0] == .nil);

    const class_one = try addClassCall(root, &runtime, &.{ self, .{ .string = "foo" } });
    defer rt.freeResults(class_one);
    const class_two = try addClassCall(root, &runtime, &.{ self, .{ .string = "bar" } });
    defer rt.freeResults(class_two);
    const css_one = try cssCall(root, &runtime, &.{ self, .{ .string = "foo" }, .{ .string = "bar" } });
    defer rt.freeResults(css_one);
    const css_raw = try cssTextCall(root, &runtime, &.{ self, .{ .string = "abc:def" } });
    defer rt.freeResults(css_raw);
    const css_two = try cssCall(root, &runtime, &.{ self, .{ .string = "g" }, .{ .string = "h" } });
    defer rt.freeResults(css_two);

    var out: std.ArrayList(u8) = .empty;
    try renderNode(root, &out);
    try std.testing.expectEqualStrings("<div town=\"Berlin\" class=\"foo bar\" style=\"foo:bar;abc:def;g:h\"></div>", out.items);

    const style_override = try attrCall(root, &runtime, &.{ self, .{ .string = "style" }, .{ .string = "color:red" } });
    defer rt.freeResults(style_override);
    out.items.len = 0;
    try renderNode(root, &out);
    try std.testing.expectEqualStrings("<div town=\"Berlin\" class=\"foo bar\" style=\"color:red\"></div>", out.items);

    const escaped = try newNode(html, &runtime, null, "div");
    try installNodeMethods(escaped, &runtime);
    const escaped_self = Value{ .table = escaped.table };
    const css_escape = try cssCall(escaped, &runtime, &.{ escaped_self, .{ .string = "background" }, .{ .string = "red;display:none é" } });
    defer rt.freeResults(css_escape);
    out.items.len = 0;
    try renderNode(escaped, &out);
    try std.testing.expectEqualStrings("<div style=\"background:red\\3B display\\3A none \\E9 \"></div>", out.items);

    try std.testing.expectError(error.HtmlAttributeValueExpected, attrCall(root, &runtime, &.{ self, .{ .string = "bad" }, .{ .boolean = true } }));
    try std.testing.expectError(error.HtmlScalarExpected, cssCall(root, &runtime, &.{ self, .{ .boolean = true }, .{ .string = "x" } }));
    try std.testing.expectError(error.HtmlScalarExpected, wikitextCall(root, &runtime, &.{ self, .{ .boolean = true } }));
}

test "html builder table setters and removals match MediaWiki behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 0);
    defer runtime.deinit();
    const html = try a.create(Html);
    html.* = .{ .allocator = a };
    const root = try newNode(html, &runtime, null, "div");
    try installNodeMethods(root, &runtime);
    const self = Value{ .table = root.table };

    const attrs = try runtime.newTable();
    try attrs.rawSet(a, .{ .string = "foo" }, .{ .string = "bar" });
    try attrs.rawSet(a, .{ .string = "count" }, .{ .number = 7 });
    const attr_result = try attrCall(root, &runtime, &.{ self, .{ .table = attrs } });
    defer rt.freeResults(attr_result);
    const count = try getAttrCall(root, &runtime, &.{ self, .{ .string = "count" } });
    defer rt.freeResults(count);
    try std.testing.expectEqual(@as(f64, 7), count[0].number);

    const styles = try runtime.newTable();
    try styles.rawSet(a, .{ .string = "color" }, .{ .string = "red" });
    try styles.rawSet(a, .{ .number = 12 }, .{ .number = 34 });
    const css_result = try cssCall(root, &runtime, &.{ self, .{ .table = styles } });
    defer rt.freeResults(css_result);
    const css_remove = try cssCall(root, &runtime, &.{ self, .{ .string = "color" }, .nil });
    defer rt.freeResults(css_remove);

    var out: std.ArrayList(u8) = .empty;
    try renderNode(root, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "foo=\"bar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "count=\"7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "12:34") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "color:red") == null);

    const bad_attrs = try runtime.newTable();
    try bad_attrs.rawSet(a, .{ .number = 1 }, .{ .string = "x" });
    try std.testing.expectError(error.HtmlAttributeTableExpected, attrCall(root, &runtime, &.{ self, .{ .table = bad_attrs } }));
    try std.testing.expectError(error.InvalidHtmlAttributeName, attrCall(root, &runtime, &.{ self, .{ .string = "§§" }, .{ .string = "x" } }));

    const style_clear = try attrCall(root, &runtime, &.{ self, .{ .string = "style" }, .nil });
    defer rt.freeResults(style_clear);
    out.items.len = 0;
    try renderNode(root, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, " style=") == null);
}

test "html builder matches MediaWiki self-closing tag semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 0);
    defer runtime.deinit();
    const html = try a.create(Html);
    html.* = .{ .allocator = a };

    const root = try newNode(html, &runtime, null, "div");
    const br = try newNode(html, &runtime, root, "br");
    try appendChild(root, .{ .node = br });
    try std.testing.expect(br.self_closing);
    try std.testing.expectError(error.HtmlSelfClosingHasChildren, appendChild(br, .{ .text = "bad" }));

    var out: std.ArrayList(u8) = .empty;
    try renderNode(root, &out);
    try std.testing.expectEqualStrings("<div><br /></div>", out.items);

    const forced = try newNode(html, &runtime, null, "div");
    forced.self_closing = true;
    out.items.len = 0;
    try renderNode(forced, &out);
    try std.testing.expectEqualStrings("<div />", out.items);
}
