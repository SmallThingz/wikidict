const std = @import("std");
const rt = @import("zig_runtime");
const Value = rt.Value;

const Pair = struct { name: []const u8, value: []const u8 };
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
    children: std.ArrayList(Child) = .empty,
    attrs: std.ArrayList(Pair) = .empty,
    styles: std.ArrayList(Pair) = .empty,
    classes: std.ArrayList([]const u8) = .empty,
    css_text: std.ArrayList([]const u8) = .empty,
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
        .boolean => |b| if (b) "true" else "false",
        .nil => "",
        else => error.HtmlScalarExpected,
    };
}

fn setPair(a: std.mem.Allocator, list: *std.ArrayList(Pair), name: []const u8, value: ?[]const u8) !void {
    for (list.items, 0..) |*pair, i| {
        if (!std.mem.eql(u8, pair.name, name)) continue;
        if (value) |v| pair.value = v else _ = list.orderedRemove(i);
        return;
    }
    if (value) |v| try list.append(a, .{ .name = name, .value = v });
}

fn returnSelf(node: *Node, a: std.mem.Allocator) ![]const Value {
    return one(a, .{ .table = node.table });
}

fn newNode(html: *Html, runtime: *rt.Context, parent: ?*Node, tag_name: ?[]const u8) !*Node {
    const node = try html.allocator.create(Node);
    const table = try runtime.newNativeNamespace(.html_node);
    node.* = .{ .html = html, .table = table, .parent = parent, .tag_name = tag_name };
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
    try installNodeMethods(node, runtime);
    return one(a, .{ .table = node.table });
}
fn tagCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len < 2 or args[1] != .string) return error.HtmlTagExpected;
    const child = try newNode(node.html, runtime, node, args[1].string);
    try installNodeMethods(child, runtime);
    try node.children.append(node.html.allocator, .{ .node = child });
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
        if (value == .nil) continue;
        try node.children.append(node.html.allocator, .{ .text = try scalarText(node.html.allocator, value) });
    }
    return returnSelf(node, a);
}
fn nodeCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    for (args[1..]) |value| switch (value) {
        .nil => {},
        .string, .number, .boolean => try node.children.append(node.html.allocator, .{ .text = try scalarText(node.html.allocator, value) }),
        .table => |table| {
            const child = node.html.nodes.get(table) orelse return error.HtmlNodeExpected;
            try node.children.append(node.html.allocator, .{ .node = child });
        },
        else => return error.HtmlNodeExpected,
    };
    return returnSelf(node, a);
}

fn cssCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len < 2 or args[1] != .string) return error.HtmlCssNameExpected;
    const value = if (args.len < 3 or args[2] == .nil) null else try scalarText(node.html.allocator, args[2]);
    try setPair(node.html.allocator, &node.styles, args[1].string, value);
    return returnSelf(node, a);
}

fn cssTextCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len >= 2 and args[1] != .nil) try node.css_text.append(node.html.allocator, try scalarText(node.html.allocator, args[1]));
    return returnSelf(node, a);
}
fn addClassCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len >= 2 and args[1] != .nil) {
        const class = try scalarText(node.html.allocator, args[1]);
        if (class.len != 0) try node.classes.append(node.html.allocator, class);
    }
    return returnSelf(node, a);
}

fn attrCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len < 2) return returnSelf(node, a);
    if (args[1] == .table) {
        var it = args[1].table.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* != .string) continue;
            const value = if (entry.value_ptr.* == .nil) null else try scalarText(node.html.allocator, entry.value_ptr.*);
            try setPair(node.html.allocator, &node.attrs, entry.key_ptr.string, value);
        }
    } else {
        if (args[1] != .string) return error.HtmlAttributeNameExpected;
        const value = if (args.len < 3 or args[2] == .nil) null else try scalarText(node.html.allocator, args[2]);
        try setPair(node.html.allocator, &node.attrs, args[1].string, value);
    }
    return returnSelf(node, a);
}
fn newlineCall(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const a = runtime.allocator;
    const node: *Node = @ptrCast(@alignCast(ctx_raw.?));
    try node.children.append(node.html.allocator, .{ .text = "\n" });
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

fn appendAttribute(out: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    try out.append(a, ' ');
    try out.appendSlice(a, name);
    try out.appendSlice(a, "=\"");
    try appendEscapedAttribute(out, a, value);
    try out.append(a, '"');
}
fn appendStyleValue(node: *Node, out: *std.ArrayList(u8)) !void {
    const a = node.html.allocator;
    var first = true;
    for (node.styles.items) |pair| {
        if (!first) try out.append(a, ';');
        try out.appendSlice(a, pair.name);
        try out.append(a, ':');
        try out.appendSlice(a, pair.value);
        first = false;
    }
    for (node.css_text.items) |text| {
        if (text.len == 0) continue;
        if (!first and out.items.len != 0 and out.items[out.items.len - 1] != ';') try out.append(a, ';');
        try out.appendSlice(a, text);
        first = false;
    }
}

fn appendClassValue(node: *Node, out: *std.ArrayList(u8)) !void {
    for (node.classes.items, 0..) |class, i| {
        if (i != 0) try out.append(node.html.allocator, ' ');
        try out.appendSlice(node.html.allocator, class);
    }
}
fn renderNode(node: *Node, out: *std.ArrayList(u8)) !void {
    const a = node.html.allocator;
    if (node.tag_name) |tag| {
        try out.append(a, '<');
        try out.appendSlice(a, tag);
        if (node.classes.items.len != 0) {
            var classes: std.ArrayList(u8) = .empty;
            try appendClassValue(node, &classes);
            try appendAttribute(out, a, "class", classes.items);
        }
        for (node.attrs.items) |pair| try appendAttribute(out, a, pair.name, pair.value);
        if (node.styles.items.len != 0 or node.css_text.items.len != 0) {
            var styles: std.ArrayList(u8) = .empty;
            try appendStyleValue(node, &styles);
            try appendAttribute(out, a, "style", styles.items);
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
    try root.classes.append(a, "box");
    try root.styles.append(a, .{ .name = "width", .value = "2px" });
    try root.attrs.append(a, .{ .name = "title", .value = "a&b" });
    const child = try newNode(html, &runtime, root, "span");
    try installNodeMethods(child, &runtime);
    try child.children.append(a, .{ .text = "wiki" });
    try root.children.append(a, .{ .node = child });
    var out: std.ArrayList(u8) = .empty;
    try renderNode(root, &out);
    try std.testing.expectEqualStrings("<div class=\"box\" title=\"a&amp;b\" style=\"width:2px\"><span>wiki</span></div>", out.items);
}
