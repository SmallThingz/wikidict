const std = @import("std");
const rt = @import("zig_runtime");
const host_api = @import("zig_host.zig");
const Value = rt.Value;

pub const FrameArg = struct { key: Value, value: Value };

const FrameCtx = struct {
    table: *rt.Table,
    parent: ?*rt.Table,
    title: []const u8,
};

fn one(value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

fn getParentCall(raw: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    const ctx: *FrameCtx = @ptrCast(@alignCast(raw orelse return error.MissingFrameContext));
    return one(if (ctx.parent) |parent| .{ .table = parent } else .nil);
}

fn getTitleCall(raw: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    const ctx: *FrameCtx = @ptrCast(@alignCast(raw orelse return error.MissingFrameContext));
    return one(.{ .string = ctx.title });
}
fn preprocessCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx: *FrameCtx = @ptrCast(@alignCast(raw orelse return error.MissingFrameContext));
    if (args.len < 2 or args[1] != .string) return error.StringExpected;
    const host = host_api.get(runtime) orelse return error.MissingScribuntoHost;
    const call = host.frame_preprocess orelse return error.NotImplemented;
    const frame_args = ctx.table.rawGet(.{ .string = "args" }) orelse return error.MissingFrameArgs;
    if (frame_args != .table) return error.TableExpected;
    return one(.{ .string = try call(host.ctx, runtime.allocator, args[1].string, ctx.title, frame_args.table) });
}

fn expandTemplateCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 2 or args[1] != .table) return error.TemplateSpecExpected;
    const host = host_api.get(runtime) orelse return error.MissingScribuntoHost;
    const call = host.frame_expand_template orelse return error.NotImplemented;
    const spec = args[1];
    const title = try runtime.getIndex(spec, .{ .string = "title" });
    if (title != .string) return error.TemplateTitleExpected;
    const raw_args = try runtime.getIndex(spec, .{ .string = "args" });
    const template_args = switch (raw_args) {
        .nil => try runtime.newTable(),
        .table => |table| table,
        else => return error.TemplateArgsExpected,
    };
    return one(.{ .string = try call(host.ctx, runtime.allocator, title.string, template_args) });
}
fn extensionTagCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 2 or args[1] != .string) return error.ExtensionTagNameExpected;
    const host = host_api.get(runtime) orelse return error.MissingScribuntoHost;
    const call = host.frame_extension_tag orelse return error.NotImplemented;
    const content: ?Value = if (args.len > 2 and args[2] != .nil) args[2] else null;
    const attrs: ?*rt.Table = if (args.len <= 3 or args[3] == .nil)
        null
    else switch (args[3]) {
        .table => |table| table,
        else => return error.TableExpected,
    };
    return one(.{ .string = try call(host.ctx, runtime.allocator, args[1].string, content, attrs) });
}

const ParserCall = struct {
    name: []const u8,
    first: ?Value = null,
    second: ?Value = null,
};

fn decodeParserCall(args: []const Value) !ParserCall {
    if (args.len < 2) return error.ParserFunctionNameExpected;
    if (args[1] == .string) return .{
        .name = args[1].string,
        .first = if (args.len > 2) args[2] else null,
        .second = if (args.len > 3) args[3] else null,
    };
    if (args[1] != .table) return error.ParserFunctionNameExpected;
    const spec = args[1].table;
    const name = spec.rawGet(.{ .string = "name" }) orelse return error.ParserFunctionNameExpected;
    if (name != .string) return error.ParserFunctionNameExpected;
    const raw_args = spec.rawGet(.{ .string = "args" });
    if (raw_args) |value| {
        if (value == .table) return .{
            .name = name.string,
            .first = value.table.rawGet(.{ .number = 1 }),
            .second = value.table.rawGet(.{ .number = 2 }),
        };
        return .{ .name = name.string, .first = value };
    }
    return .{ .name = name.string };
}

fn parserFunctionCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const parsed = try decodeParserCall(args);
    const host = host_api.get(runtime) orelse return error.MissingScribuntoHost;
    const call = host.frame_parser_function orelse return error.NotImplemented;
    return one(.{ .string = try call(host.ctx, runtime.allocator, parsed.name, parsed.first, parsed.second) });
}

fn currentFrameCall(_: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    return one(if (runtime.current_frame) |frame| .{ .table = frame } else .nil);
}
fn makeFrameWithArgs(runtime: *rt.Context, title: []const u8, arg_table: *rt.Table, parent: ?Value) !Value {
    const frame = try runtime.newTable();
    const parent_table: ?*rt.Table = if (parent) |value| switch (value) {
        .nil => null,
        .table => |table| table,
        else => return error.ParentFrameExpected,
    } else null;
    const ctx = try runtime.allocator.create(FrameCtx);
    ctx.* = .{ .table = frame, .parent = parent_table, .title = try runtime.allocator.dupe(u8, title) };
    try frame.rawSet(runtime.allocator, .{ .string = "args" }, .{ .table = arg_table });
    try frame.rawSet(runtime.allocator, .{ .string = "getParent" }, try runtime.newNative(ctx, getParentCall));
    try frame.rawSet(runtime.allocator, .{ .string = "getTitle" }, try runtime.newNative(ctx, getTitleCall));
    try frame.rawSet(runtime.allocator, .{ .string = "preprocess" }, try runtime.newNative(ctx, preprocessCall));
    try frame.rawSet(runtime.allocator, .{ .string = "expandTemplate" }, try runtime.newNative(ctx, expandTemplateCall));
    try frame.rawSet(runtime.allocator, .{ .string = "extensionTag" }, try runtime.newNative(ctx, extensionTagCall));
    try frame.rawSet(runtime.allocator, .{ .string = "callParserFunction" }, try runtime.newNative(ctx, parserFunctionCall));
    return .{ .table = frame };
}

pub fn makeFrame(runtime: *rt.Context, title: []const u8, args: []const FrameArg, parent: ?Value) !Value {
    const table = try runtime.newTable();
    for (args) |arg| try table.rawSet(runtime.allocator, arg.key, arg.value);
    return makeFrameWithArgs(runtime, title, table, parent);
}

pub fn install(runtime: *rt.Context, mw: *rt.Table) !void {
    try mw.rawSet(runtime.allocator, .{ .string = "getCurrentFrame" }, try runtime.newNative(null, currentFrameCall));
}
pub fn invoke(runtime: *rt.Context, module_name: []const u8, function_name: []const u8, frame: Value) anyerror![]const Value {
    if (frame != .table) return error.FrameExpected;
    const saved = runtime.current_frame;
    runtime.current_frame = frame.table;
    defer runtime.current_frame = saved;
    const module = try runtime.requireByName(module_name);
    const callable = if (function_name.len == 0)
        module
    else
        try runtime.getIndex(module, .{ .string = function_name });
    return runtime.callValue(callable, &.{frame});
}

fn callField(runtime: *rt.Context, object: Value, name: []const u8, args: []const Value) ![]const Value {
    const callable = try runtime.getIndex(object, .{ .string = name });
    return runtime.callValue(callable, args);
}

const Probe = struct {
    var preprocess_seen: bool = false;
    var template_seen: bool = false;
    var extension_seen: bool = false;
    var parser_seen: bool = false;

    fn preprocess(_: ?*anyopaque, a: std.mem.Allocator, source: []const u8, title: []const u8, args: *rt.Table) ![]const u8 {
        preprocess_seen = std.mem.eql(u8, source, "{{x}}") and std.mem.eql(u8, title, "Module:Probe") and args.rawGet(.{ .string = "x" }) != null;
        return try a.dupe(u8, "preprocessed");
    }
    fn expandTemplate(_: ?*anyopaque, a: std.mem.Allocator, title: []const u8, args: *rt.Table) ![]const u8 {
        template_seen = std.mem.eql(u8, title, "T") and args.rawGet(.{ .number = 1 }) != null;
        return try a.dupe(u8, "expanded");
    }

    fn extensionTag(_: ?*anyopaque, a: std.mem.Allocator, name: []const u8, content: ?Value, attrs: ?*rt.Table) ![]const u8 {
        extension_seen = std.mem.eql(u8, name, "ref") and content != null and content.? == .string and std.mem.eql(u8, content.?.string, "body") and attrs != null;
        return try a.dupe(u8, "<ref>body</ref>");
    }

    fn parser(_: ?*anyopaque, a: std.mem.Allocator, name: []const u8, first: ?Value, second: ?Value) ![]const u8 {
        parser_seen = std.mem.eql(u8, name, "#if") and first != null and first.? == .string and std.mem.eql(u8, first.?.string, "x") and second != null;
        return try a.dupe(u8, "parser");
    }
};

test "AOT frame exposes parent title and typed host callbacks" {
    Probe.preprocess_seen = false;
    Probe.template_seen = false;
    Probe.extension_seen = false;
    Probe.parser_seen = false;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{
        .frame_preprocess = Probe.preprocess,
        .frame_expand_template = Probe.expandTemplate,
        .frame_extension_tag = Probe.extensionTag,
        .frame_parser_function = Probe.parser,
    };
    host_api.set(&runtime, &host);
    const mw = try runtime.newTable();
    try install(&runtime, mw);
    const parent = try makeFrame(&runtime, "Parent", &.{}, null);
    const frame = try makeFrame(&runtime, "Module:Probe", &.{.{ .key = .{ .string = "x" }, .value = .{ .string = "y" } }}, parent);

    const title = try callField(&runtime, frame, "getTitle", &.{frame});
    defer rt.freeResults(title);
    try std.testing.expectEqualStrings("Module:Probe", title[0].string);
    const got_parent = try callField(&runtime, frame, "getParent", &.{frame});
    defer rt.freeResults(got_parent);
    try std.testing.expect(got_parent[0] == .table and got_parent[0].table == parent.table);

    runtime.current_frame = frame.table;
    const current = try callField(&runtime, .{ .table = mw }, "getCurrentFrame", &.{});
    defer rt.freeResults(current);
    try std.testing.expect(current[0] == .table and current[0].table == frame.table);
    const preprocessed = try callField(&runtime, frame, "preprocess", &.{ frame, .{ .string = "{{x}}" } });
    defer rt.freeResults(preprocessed);
    try std.testing.expectEqualStrings("preprocessed", preprocessed[0].string);

    const spec_args = try runtime.newTable();
    try spec_args.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "a" });
    const spec = try runtime.newTable();
    try spec.rawSet(runtime.allocator, .{ .string = "title" }, .{ .string = "T" });
    try spec.rawSet(runtime.allocator, .{ .string = "args" }, .{ .table = spec_args });
    const expanded = try callField(&runtime, frame, "expandTemplate", &.{ frame, .{ .table = spec } });
    defer rt.freeResults(expanded);
    try std.testing.expectEqualStrings("expanded", expanded[0].string);

    const attrs = try runtime.newTable();
    try attrs.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = "n" });
    const tag = try callField(&runtime, frame, "extensionTag", &.{ frame, .{ .string = "ref" }, .{ .string = "body" }, .{ .table = attrs } });
    defer rt.freeResults(tag);
    try std.testing.expectEqualStrings("<ref>body</ref>", tag[0].string);
    const parser = try callField(&runtime, frame, "callParserFunction", &.{ frame, .{ .string = "#if" }, .{ .string = "x" }, .{ .string = "yes" } });
    defer rt.freeResults(parser);
    try std.testing.expectEqualStrings("parser", parser[0].string);
    try std.testing.expect(Probe.preprocess_seen and Probe.template_seen and Probe.extension_seen and Probe.parser_seen);
}

const InvokeProbe = struct {
    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        return if (std.mem.eql(u8, raw_name, "Module:X")) 0 else null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return if (id == 0) "Module:X" else null;
    }
    fn root(runtime: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const module = try runtime.newTable();
        try module.rawSet(runtime.allocator, .{ .string = "run" }, try runtime.makeFunction(1, &.{}));
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = module };
        return out;
    }
    fn run(runtime: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
        const ok = args.len != 0 and args[0] == .table and runtime.current_frame == args[0].table;
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .boolean = ok };
        return out;
    }
};

test "AOT frame invoke binds current frame around numeric module call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 0, 1);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ InvokeProbe.root, InvokeProbe.run };
    const blocks = [_]rt.FunctionBlock{.{ .first = 0, .values = &functions }};
    const roots = [_]u32{0};
    runtime.function_blocks = &blocks;
    runtime.module_roots = &roots;
    runtime.configureModules(null, InvokeProbe.lookup, InvokeProbe.name);
    const frame = try makeFrame(&runtime, "Module:X", &.{}, null);
    try std.testing.expect(runtime.current_frame == null);
    const out = try invoke(&runtime, "Module:X", "run", frame);
    defer rt.freeResults(out);
    try std.testing.expect(out.len == 1 and out[0] == .boolean and out[0].boolean);
    try std.testing.expect(runtime.current_frame == null);
}
