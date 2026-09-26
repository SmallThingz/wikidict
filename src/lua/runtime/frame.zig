const std = @import("std");
const rt = @import("zig_runtime");
const host_api = @import("host.zig");
const stdlib = @import("zig_stdlib");
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
    if (args.len < 2) return error.StringExpected;
    const source = if (args[1] == .table)
        try runtime.getIndex(args[1], .{ .string = "text" })
    else
        args[1];
    const host = host_api.get(runtime) orelse return error.MissingScribuntoHost;
    const call = host.frame_preprocess orelse return error.NotImplemented;
    const frame_args = ctx.table.rawGet(.{ .string = "args" }) orelse return error.MissingFrameArgs;
    if (frame_args != .table) return error.TableExpected;
    return one(.{ .string = try call(host.ctx, runtime.allocator, try valueToString(runtime, source), ctx.title, frame_args.table) });
}

fn expandTemplateCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 2 or args[1] != .table) return error.TemplateSpecExpected;
    const host = host_api.get(runtime) orelse return error.MissingScribuntoHost;
    const call = host.frame_expand_template orelse return error.NotImplemented;
    const spec = args[1];
    const title_value = try runtime.getIndex(spec, .{ .string = "title" });
    if (title_value == .nil) return error.TemplateTitleExpected;
    var title = try valueToString(runtime, title_value);
    if (title_value == .table) {
        const namespace = try runtime.getIndex(title_value, .{ .string = "namespace" });
        if (namespace == .number and namespace.number == 0)
            title = try std.fmt.allocPrint(runtime.allocator, ":{s}", .{title});
    }
    const raw_args = try runtime.getIndex(spec, .{ .string = "args" });
    const template_args = switch (raw_args) {
        .nil => try runtime.newTable(),
        .table => |table| try checkedFrameArgs(runtime, table),
        else => return error.TemplateArgsExpected,
    };
    return one(.{ .string = try call(host.ctx, runtime.allocator, title, template_args) });
}

fn extensionTagCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 2) return error.ExtensionTagNameExpected;
    var name = args[1];
    var content: Value = if (args.len > 2) args[2] else .nil;
    var raw_attrs: Value = if (args.len > 3) args[3] else .nil;
    if (name == .table) {
        const spec = name;
        name = try runtime.getIndex(spec, .{ .string = "name" });
        content = try runtime.getIndex(spec, .{ .string = "content" });
        raw_attrs = try runtime.getIndex(spec, .{ .string = "args" });
    }
    if (name != .string and name != .number) return error.ExtensionTagNameExpected;
    const name_text = try valueToString(runtime, name);
    const content_value: ?Value = switch (content) {
        .nil => null,
        .string, .number => .{ .string = try valueToString(runtime, content) },
        else => return error.ExtensionTagContentExpected,
    };
    const attrs: ?*rt.Table = switch (raw_attrs) {
        .nil => null,
        .table => |table| try checkedFrameArgs(runtime, table),
        else => return error.TableExpected,
    };
    const host = host_api.get(runtime) orelse return error.MissingScribuntoHost;
    const call = host.frame_extension_tag orelse return error.NotImplemented;
    return one(.{ .string = try call(host.ctx, runtime.allocator, name_text, content_value, attrs) });
}

const ParserCall = struct {
    name: []const u8,
    args: *rt.Table,
};

fn setCheckedFrameArg(runtime: *rt.Context, out: *rt.Table, key: Value, value: Value) !void {
    if (key != .string and key != .number) return error.InvalidFrameArgKey;
    const text = switch (value) {
        .boolean => |v| if (v) "1" else "",
        .string, .number => try valueToString(runtime, value),
        else => return error.InvalidFrameArgValue,
    };
    try out.rawSet(runtime.allocator, key, .{ .string = text });
}

fn checkedFrameArgs(runtime: *rt.Context, source: *rt.Table) !*rt.Table {
    const out = try runtime.newTable();
    const object = Value{ .table = source };
    if (source.metatable) |mt| if (mt.rawGet(.{ .string = "__pairs" })) |method| {
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
            try setCheckedFrameArg(runtime, out, key, if (result.len > 1) result[1] else .nil);
        }
        return out;
    };
    var it = source.iterator();
    while (it.next()) |entry| try setCheckedFrameArg(runtime, out, entry.key_ptr.*, entry.value_ptr.*);
    return out;
}

fn positionalParserArgs(runtime: *rt.Context, values: []const Value) !*rt.Table {
    const table = try runtime.newTable();
    for (values, 1..) |value, index| {
        if (value == .nil) continue;
        try setCheckedFrameArg(runtime, table, .{ .number = @floatFromInt(index) }, value);
    }
    return table;
}

fn decodeParserCall(runtime: *rt.Context, args: []const Value) !ParserCall {
    if (args.len < 2) return error.ParserFunctionNameExpected;
    if (args[1] == .string or args[1] == .number) return .{
        .name = try valueToString(runtime, args[1]),
        .args = if (args.len > 2 and args[2] == .table)
            try checkedFrameArgs(runtime, args[2].table)
        else
            try positionalParserArgs(runtime, args[2..]),
    };
    if (args[1] != .table) return error.ParserFunctionNameExpected;
    const spec = args[1];
    const name = try runtime.getIndex(spec, .{ .string = "name" });
    if (name != .string and name != .number) return error.ParserFunctionNameExpected;
    const raw_args = try runtime.getIndex(spec, .{ .string = "args" });
    return .{
        .name = try valueToString(runtime, name),
        .args = if (raw_args == .table) try checkedFrameArgs(runtime, raw_args.table) else try positionalParserArgs(runtime, &.{raw_args}),
    };
}

fn parserFunctionCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const parsed = try decodeParserCall(runtime, args);
    const host = host_api.get(runtime) orelse return error.MissingScribuntoHost;
    const call = host.frame_parser_function orelse return error.NotImplemented;
    return one(.{ .string = try call(host.ctx, runtime.allocator, parsed.name, parsed.args) });
}

fn valueToString(runtime: *rt.Context, value: Value) ![]const u8 {
    // Frame titles/arguments may embed the default address-bearing object
    // representation. Such a result cannot be reused between page contexts.
    if (value == .table or value == .callable) rt.markLoadDataEffect();
    if (runtime.metamethod(value, "__tostring")) |mm| {
        const out = try runtime.callValue(mm, &.{value});
        defer rt.freeResults(out);
        if (out.len == 0 or out[0] != .string) return error.StringExpected;
        return out[0].string;
    }
    return switch (value) {
        .nil => "nil",
        .boolean => |v| if (v) "true" else "false",
        .number => |v| try rt.numberToString(runtime.allocator, v),
        .string => |v| v,
        .table => |v| try std.fmt.allocPrint(runtime.allocator, "table: 0x{x}", .{@intFromPtr(v)}),
        .callable => |v| try std.fmt.allocPrint(runtime.allocator, "function: 0x{x}", .{v.identity}),
    };
}

fn newChildCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx: *FrameCtx = @ptrCast(@alignCast(raw orelse return error.MissingFrameContext));
    if (args.len < 2 or args[1] != .table) return error.FrameChildSpecExpected;
    const spec = args[1];
    const title_value = try runtime.getIndex(spec, .{ .string = "title" });
    const title: []const u8 = if (title_value == .nil) ctx.title else try valueToString(runtime, title_value);
    const raw_args = try runtime.getIndex(spec, .{ .string = "args" });
    const child_args = switch (raw_args) {
        .nil => try runtime.newTable(),
        .table => |table| try checkedFrameArgs(runtime, table),
        else => return error.FrameChildArgsExpected,
    };
    return one(try makeFrameWithArgs(runtime, title, child_args, .{ .table = ctx.table }));
}

fn currentFrameCall(_: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    return one(if (runtime.current_frame) |frame| .{ .table = frame } else .nil);
}
fn makeFrameWithArgs(runtime: *rt.Context, title: []const u8, arg_table: *rt.Table, parent: ?Value) !Value {
    const frame = try runtime.newNativeNamespace(.frame);
    const parent_table: ?*rt.Table = if (parent) |value| switch (value) {
        .nil => null,
        .table => |table| table,
        else => return error.ParentFrameExpected,
    } else null;
    const ctx = try runtime.allocator.create(FrameCtx);
    ctx.* = .{ .table = frame, .parent = parent_table, .title = try runtime.allocator.dupe(u8, title) };
    try frame.rawSetNativeField(.frame, "args", .{ .table = arg_table });
    try frame.rawSetNativeField(.frame, "getParent", try runtime.newNative(ctx, getParentCall));
    try frame.rawSetNativeField(.frame, "getTitle", try runtime.newNative(ctx, getTitleCall));
    try frame.rawSetNativeField(.frame, "preprocess", try runtime.newNative(ctx, preprocessCall));
    try frame.rawSetNativeField(.frame, "expandTemplate", try runtime.newNative(ctx, expandTemplateCall));
    try frame.rawSetNativeField(.frame, "extensionTag", try runtime.newNative(ctx, extensionTagCall));
    try frame.rawSetNativeField(.frame, "callParserFunction", try runtime.newNative(ctx, parserFunctionCall));
    try frame.rawSetNativeField(.frame, "newChild", try runtime.newNative(ctx, newChildCall));
    return .{ .table = frame };
}

pub fn makeFrameFromTable(runtime: *rt.Context, title: []const u8, args: *rt.Table, parent: ?Value) !Value {
    return makeFrameWithArgs(runtime, title, args, parent);
}

pub fn makeFrame(runtime: *rt.Context, title: []const u8, args: []const FrameArg, parent: ?Value) !Value {
    const table = try runtime.newTable();
    for (args) |arg| try table.rawSet(runtime.allocator, arg.key, arg.value);
    return makeFrameWithArgs(runtime, title, table, parent);
}

pub fn install(runtime: *rt.Context, mw: *rt.Table) !void {
    try mw.rawSetNativeField(.mw, "getCurrentFrame", try runtime.newNative(null, currentFrameCall));
}
fn invokeValue(runtime: *rt.Context, module: Value, function_name: []const u8, frame: Value) anyerror![]const Value {
    const callable = if (function_name.len == 0)
        module
    else
        try runtime.getIndex(module, .{ .string = function_name });
    return runtime.callValue(callable, &.{frame});
}

fn invokeValueFixed(runtime: *rt.Context, module: Value, function_name: []const u8, frame: Value, result_buffer: []Value) anyerror!rt.FixedCallResult {
    const callable = if (function_name.len == 0)
        module
    else
        try runtime.getIndex(module, .{ .string = function_name });
    return runtime.callValueFixed(callable, &.{frame}, result_buffer);
}

fn enterInvoke(runtime: *rt.Context) !?*host_api.Host {
    const host = host_api.getForInvokeBookkeeping(runtime) orelse return null;
    if (host.invoke_depth == 0) try stdlib.resetMathRandom(runtime);
    host.invoke_depth +%= 1;
    return host;
}
fn leaveInvoke(host: ?*host_api.Host) void {
    if (host) |value| {
        std.debug.assert(value.invoke_depth != 0);
        value.invoke_depth -= 1;
    }
}

pub fn invokeModuleId(runtime: *rt.Context, module_id: u32, module_name: []const u8, function_name: []const u8, frame: Value) anyerror![]const Value {
    if (frame != .table) return error.FrameExpected;
    const invoke_host = try enterInvoke(runtime);
    defer leaveInvoke(invoke_host);
    const saved = runtime.current_frame;
    runtime.current_frame = frame.table;
    defer runtime.current_frame = saved;
    const module = try runtime.requireModuleId(module_id, module_name);
    const callable = if (function_name.len == 0)
        module
    else if (runtime.moduleExportSlot(module_id, function_name)) |known|
        try runtime.getProgramShapeField(module, known.shape_id, known.slot, function_name)
    else
        try runtime.getIndex(module, .{ .string = function_name });
    return runtime.callValue(callable, &.{frame});
}

/// Invoke for callers that consume only the first result. Generated functions
/// write into result_buffer; legacy functions may return an owned result slice.
pub fn invokeModuleIdFixed(runtime: *rt.Context, module_id: u32, module_name: []const u8, function_name: []const u8, frame: Value, result_buffer: []Value) anyerror!rt.FixedCallResult {
    if (frame != .table) return error.FrameExpected;
    const invoke_host = try enterInvoke(runtime);
    defer leaveInvoke(invoke_host);
    const saved = runtime.current_frame;
    runtime.current_frame = frame.table;
    defer runtime.current_frame = saved;
    const module = try runtime.requireModuleId(module_id, module_name);
    const callable = if (function_name.len == 0)
        module
    else if (runtime.moduleExportSlot(module_id, function_name)) |known|
        try runtime.getProgramShapeField(module, known.shape_id, known.slot, function_name)
    else
        try runtime.getIndex(module, .{ .string = function_name });
    return runtime.callValueFixed(callable, &.{frame}, result_buffer);
}

pub fn invokeFixed(runtime: *rt.Context, module_name: []const u8, function_name: []const u8, frame: Value, result_buffer: []Value) anyerror!rt.FixedCallResult {
    if (frame != .table) return error.FrameExpected;
    const invoke_host = try enterInvoke(runtime);
    defer leaveInvoke(invoke_host);
    const saved = runtime.current_frame;
    runtime.current_frame = frame.table;
    defer runtime.current_frame = saved;
    const module = try runtime.requireByName(module_name);
    return invokeValueFixed(runtime, module, function_name, frame, result_buffer);
}

pub fn invoke(runtime: *rt.Context, module_name: []const u8, function_name: []const u8, frame: Value) anyerror![]const Value {
    if (frame != .table) return error.FrameExpected;
    const invoke_host = try enterInvoke(runtime);
    defer leaveInvoke(invoke_host);
    const saved = runtime.current_frame;
    runtime.current_frame = frame.table;
    defer runtime.current_frame = saved;
    const module = try runtime.requireByName(module_name);
    return invokeValue(runtime, module, function_name, frame);
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
        const flag = args.rawGet(.{ .string = "flag" });
        template_seen = std.mem.eql(u8, title, "T") and args.rawGet(.{ .number = 1 }) != null and
            flag != null and flag.? == .string and std.mem.eql(u8, flag.?.string, "1");
        return try a.dupe(u8, "expanded");
    }

    fn extensionTag(_: ?*anyopaque, a: std.mem.Allocator, name: []const u8, content: ?Value, attrs: ?*rt.Table) ![]const u8 {
        const enabled = if (attrs) |table| table.rawGet(.{ .string = "enabled" }) else null;
        extension_seen = std.mem.eql(u8, name, "ref") and content != null and content.? == .string and
            std.mem.eql(u8, content.?.string, "body") and enabled != null and enabled.? == .string and
            std.mem.eql(u8, enabled.?.string, "1");
        return try a.dupe(u8, "<ref>body</ref>");
    }

    fn parser(_: ?*anyopaque, a: std.mem.Allocator, name: []const u8, args: *rt.Table) ![]const u8 {
        const first = args.rawGet(.{ .number = 1 });
        const second = args.rawGet(.{ .number = 2 });
        const third = args.rawGet(.{ .number = 3 });
        const named = args.rawGet(.{ .string = "named" });
        const flag = args.rawGet(.{ .string = "flag" });
        parser_seen = std.mem.eql(u8, name, "#if") and first != null and first.? == .string and std.mem.eql(u8, first.?.string, "x") and
            second != null and third != null and named != null and named.? == .string and std.mem.eql(u8, named.?.string, "attr") and
            flag != null and flag.? == .string and std.mem.eql(u8, flag.?.string, "1");
        return try a.dupe(u8, if (named != null and named.? == .string and std.mem.eql(u8, named.?.string, "attr")) "parser-named" else "parser");
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
    const mw = try runtime.newNativeNamespace(.mw);
    try install(&runtime, mw);
    const parent = try makeFrame(&runtime, "Parent", &.{}, null);
    const frame = try makeFrame(&runtime, "Module:Probe", &.{.{ .key = .{ .string = "x" }, .value = .{ .string = "y" } }}, parent);

    const title = try callField(&runtime, frame, "getTitle", &.{frame});
    defer rt.freeResults(title);
    try std.testing.expectEqualStrings("Module:Probe", title[0].string);
    const got_parent = try callField(&runtime, frame, "getParent", &.{frame});
    defer rt.freeResults(got_parent);
    try std.testing.expect(got_parent[0] == .table and got_parent[0].table == parent.table);

    const child_args = try runtime.newTable();
    try child_args.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = "value" });
    try child_args.rawSet(runtime.allocator, .{ .number = 1 }, .{ .number = 42 });
    try child_args.rawSet(runtime.allocator, .{ .string = "flag" }, .{ .boolean = false });
    const child_spec = try runtime.newTable();
    try child_spec.rawSet(runtime.allocator, .{ .string = "args" }, .{ .table = child_args });
    const child_result = try callField(&runtime, frame, "newChild", &.{ frame, .{ .table = child_spec } });
    defer rt.freeResults(child_result);
    const child = child_result[0];
    const child_title = try callField(&runtime, child, "getTitle", &.{child});
    defer rt.freeResults(child_title);
    try std.testing.expectEqualStrings("Module:Probe", child_title[0].string);
    const child_parent = try callField(&runtime, child, "getParent", &.{child});
    defer rt.freeResults(child_parent);
    try std.testing.expect(child_parent[0] == .table and child_parent[0].table == frame.table);
    const child_frame_args = (try runtime.getIndex(child, .{ .string = "args" })).table;
    try std.testing.expectEqualStrings("value", child_frame_args.rawGet(.{ .string = "name" }).?.string);
    try std.testing.expectEqualStrings("42", child_frame_args.rawGet(.{ .number = 1 }).?.string);
    try std.testing.expectEqualStrings("", child_frame_args.rawGet(.{ .string = "flag" }).?.string);
    const titled_spec = try runtime.newTable();
    try titled_spec.rawSet(runtime.allocator, .{ .string = "title" }, .{ .number = 123 });
    const titled_child = try callField(&runtime, frame, "newChild", &.{ frame, .{ .table = titled_spec } });
    defer rt.freeResults(titled_child);
    const titled_name = try callField(&runtime, titled_child[0], "getTitle", &.{titled_child[0]});
    defer rt.freeResults(titled_name);
    try std.testing.expectEqualStrings("123", titled_name[0].string);

    runtime.current_frame = frame.table;
    const current = try callField(&runtime, .{ .table = mw }, "getCurrentFrame", &.{});
    defer rt.freeResults(current);
    try std.testing.expect(current[0] == .table and current[0].table == frame.table);
    const preprocessed = try callField(&runtime, frame, "preprocess", &.{ frame, .{ .string = "{{x}}" } });
    defer rt.freeResults(preprocessed);
    try std.testing.expectEqualStrings("preprocessed", preprocessed[0].string);
    const preprocess_spec = try runtime.newTable();
    try preprocess_spec.rawSet(runtime.allocator, .{ .string = "text" }, .{ .string = "{{x}}" });
    const preprocessed_spec = try callField(&runtime, frame, "preprocess", &.{ frame, .{ .table = preprocess_spec } });
    defer rt.freeResults(preprocessed_spec);
    try std.testing.expectEqualStrings("preprocessed", preprocessed_spec[0].string);

    const spec_args = try runtime.newTable();
    try spec_args.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "a" });
    try spec_args.rawSet(runtime.allocator, .{ .string = "flag" }, .{ .boolean = true });
    const spec = try runtime.newTable();
    try spec.rawSet(runtime.allocator, .{ .string = "title" }, .{ .string = "T" });
    try spec.rawSet(runtime.allocator, .{ .string = "args" }, .{ .table = spec_args });
    const expanded = try callField(&runtime, frame, "expandTemplate", &.{ frame, .{ .table = spec } });
    defer rt.freeResults(expanded);
    try std.testing.expectEqualStrings("expanded", expanded[0].string);

    const attrs = try runtime.newTable();
    try attrs.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = "n" });
    try attrs.rawSet(runtime.allocator, .{ .string = "enabled" }, .{ .boolean = true });
    const tag = try callField(&runtime, frame, "extensionTag", &.{ frame, .{ .string = "ref" }, .{ .string = "body" }, .{ .table = attrs } });
    defer rt.freeResults(tag);
    try std.testing.expectEqualStrings("<ref>body</ref>", tag[0].string);
    const tag_spec = try runtime.newTable();
    try tag_spec.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = "ref" });
    try tag_spec.rawSet(runtime.allocator, .{ .string = "content" }, .{ .string = "body" });
    try tag_spec.rawSet(runtime.allocator, .{ .string = "args" }, .{ .table = attrs });
    const table_tag = try callField(&runtime, frame, "extensionTag", &.{ frame, .{ .table = tag_spec } });
    defer rt.freeResults(table_tag);
    try std.testing.expectEqualStrings("<ref>body</ref>", table_tag[0].string);
    const parser = try callField(&runtime, frame, "callParserFunction", &.{ frame, .{ .string = "#if" }, .{ .string = "x" }, .{ .string = "yes" }, .{ .string = "tail" } });
    defer rt.freeResults(parser);
    try std.testing.expectEqualStrings("parser", parser[0].string);
    const parser_args = try runtime.newTable();
    try parser_args.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "x" });
    try parser_args.rawSet(runtime.allocator, .{ .number = 2 }, .{ .string = "yes" });
    try parser_args.rawSet(runtime.allocator, .{ .number = 3 }, .{ .string = "tail" });
    try parser_args.rawSet(runtime.allocator, .{ .string = "named" }, .{ .string = "attr" });
    try parser_args.rawSet(runtime.allocator, .{ .string = "flag" }, .{ .boolean = true });
    const direct_table_parser = try callField(&runtime, frame, "callParserFunction", &.{ frame, .{ .string = "#if" }, .{ .table = parser_args } });
    defer rt.freeResults(direct_table_parser);
    try std.testing.expectEqualStrings("parser-named", direct_table_parser[0].string);
    const parser_spec = try runtime.newTable();
    try parser_spec.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = "#if" });
    try parser_spec.rawSet(runtime.allocator, .{ .string = "args" }, .{ .table = parser_args });
    const named_parser = try callField(&runtime, frame, "callParserFunction", &.{ frame, .{ .table = parser_spec } });
    defer rt.freeResults(named_parser);
    try std.testing.expectEqualStrings("parser-named", named_parser[0].string);
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
        try module.rawSet(runtime.allocator, .{ .string = "run" }, try runtime.makeFunctionKnown(1, run, &.{}));
        try module.rawSet(runtime.allocator, .{ .string = "buffered" }, try runtime.makeFunction(2, rt.stabilizeBuffered(runBuffered), &.{}));
        try module.rawSet(runtime.allocator, .{ .string = "empty" }, try runtime.makeFunction(3, rt.stabilizeBuffered(runEmpty), &.{}));
        try module.rawSet(runtime.allocator, .{ .string = "nil_return" }, try runtime.makeFunction(4, rt.stabilizeBuffered(runNil), &.{}));
        try module.rawSet(runtime.allocator, .{ .string = "error_nil" }, try runtime.makeFunction(5, rt.stabilizeBuffered(runErrorNil), &.{}));
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
    fn runBuffered(runtime: *rt.Context, _: rt.Captures, args: []const Value, buffer: ?[]Value) ![]const Value {
        const ok = args.len == 1 and args[0] == .table and runtime.current_frame == args[0].table and
            buffer != null and buffer.?.len == 1;
        const out = try rt.returnBuffer(buffer, 2);
        rt.storeReturn(out, 0, .{ .boolean = ok });
        rt.storeReturn(out, 1, .{ .number = 9 });
        return out;
    }
    fn runEmpty(_: *rt.Context, _: rt.Captures, _: []const Value, buffer: ?[]Value) ![]const Value {
        return try rt.returnBuffer(buffer, 0);
    }
    fn runNil(_: *rt.Context, _: rt.Captures, _: []const Value, buffer: ?[]Value) ![]const Value {
        const out = try rt.returnBuffer(buffer, 1);
        rt.storeReturn(out, 0, .nil);
        return out;
    }
    fn runErrorNil(runtime: *rt.Context, _: rt.Captures, _: []const Value, _: ?[]Value) ![]const Value {
        runtime.setLuaError(.nil);
        return error.LuaRaised;
    }
};

test "AOT frame invoke binds current frame around numeric module call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 0, 1);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(InvokeProbe.root), rt.stabilize(InvokeProbe.run) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, InvokeProbe.lookup, InvokeProbe.name);
    const frame = try makeFrame(&runtime, "Module:X", &.{}, null);
    try std.testing.expect(runtime.current_frame == null);
    const out = try invoke(&runtime, "Module:X", "run", frame);
    defer rt.freeResults(out);
    try std.testing.expect(out.len == 1 and out[0] == .boolean and out[0].boolean);
    try std.testing.expect(runtime.current_frame == null);

    var slot: [1]Value = undefined;
    const legacy = try invokeFixed(&runtime, "Module:X", "run", frame, &slot);
    defer legacy.deinit();
    try std.testing.expect(legacy.owned and legacy.values.len == 1 and legacy.values[0].boolean);
    try std.testing.expect(runtime.current_frame == null);

    const buffered = try invokeModuleIdFixed(&runtime, 0, "Module:X", "buffered", frame, &slot);
    defer buffered.deinit();
    try std.testing.expect(!buffered.owned and buffered.values.len == 1 and buffered.values.ptr == slot[0..].ptr);
    try std.testing.expect(buffered.values[0].boolean);
    try std.testing.expect(runtime.current_frame == null);

    const empty = try invokeFixed(&runtime, "Module:X", "empty", frame, &slot);
    defer empty.deinit();
    try std.testing.expect(!empty.owned and empty.values.len == 0);
    const nil_result = try invokeFixed(&runtime, "Module:X", "nil_return", frame, &slot);
    defer nil_result.deinit();
    try std.testing.expect(!nil_result.owned and nil_result.values.len == 1 and nil_result.values[0] == .nil);
    try std.testing.expect(runtime.current_frame == null);

    try std.testing.expectError(error.AotCallFailed, invokeFixed(&runtime, "Module:X", "error_nil", frame, &slot));
    try std.testing.expect(runtime.last_error_present and runtime.last_error == .nil);
    try std.testing.expect(runtime.current_frame == null);
    runtime.clearLuaError();
    runtime.clearAotErrorName();
    const old_limit = runtime.max_depth;
    runtime.max_depth = 0;
    try std.testing.expectError(error.CallDepth, invokeFixed(&runtime, "Module:X", "buffered", frame, &slot));
    runtime.max_depth = old_limit;
    try std.testing.expect(runtime.depth == 0 and runtime.current_frame == null);
}
