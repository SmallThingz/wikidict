const std = @import("std");
const lua = @import("lua");
const decoder = @import("decoder");
const compact_pattern_seed = @import("compact_pattern_seed");
const required_path = @import("required_path");

const support_import = "template_compiler_support.zig";

pub fn main(init: std.process.Init) !void {
    const args_allocator = init.arena.allocator();
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(args_allocator);
    const options = try parseOptions(args[1..]);

    required_path.ensureExistsOrExit(init.io, options.input_path, "wiktionary dump");
    if (options.template_name == null) {
        required_path.ensureExistsOrExit(init.io, options.db_path, "dictionary binary");
    }

    var sources = try lua.scanTemplateAndModuleSourcesAlloc(allocator, options.input_path);
    defer sources.deinit(allocator);

    const roots = if (options.template_name) |name| blk: {
        const out = try allocator.alloc([]const u8, 1);
        out[0] = try allocator.dupe(u8, name);
        break :blk out;
    } else try loadDbTemplateNamesAlloc(allocator, options.db_path);
    defer freeOwnedStrings(allocator, roots);

    var report = try lua.analyzeTemplateDependenciesFromSourcesAlloc(allocator, roots, &sources);
    defer report.deinit(allocator);

    const generated = try compileTemplateRuntimeAlloc(allocator, report.reachable_templates, &sources);
    defer allocator.free(generated);

    var file = try std.Io.Dir.cwd().createFile(init.io, options.output_path, .{ .truncate = true });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, generated);

    std.debug.print(
        "template compiler: roots={d} reachable={d} output={s}\n",
        .{ roots.len, report.reachable_templates.len, options.output_path },
    );
}

const Options = struct {
    input_path: []const u8 = "data/wiktionary.xml",
    db_path: []const u8 = "data/wiktionary.bin",
    output_path: []const u8 = "renderer/generated_template_runtime.zig",
    template_name: ?[]const u8 = null,
};

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.input_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--db")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.db_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.output_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--template")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.template_name = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        }
    }
    return options;
}

fn printUsage() void {
    std.debug.print(
        \\dict-template-compile --input data/wiktionary.xml --db data/wiktionary.bin --output renderer/generated_template_runtime.zig
        \\dict-template-compile --input data/wiktionary.xml --template \"template name\" --output /tmp/generated_templates.zig
        \\
    , .{});
}

const CompileClass = enum {
    metadata_only,
    compiled,
    unsupported,
};

const Node = union(enum) {
    text: []const u8,
    param: ParamNode,
    template_call: TemplateCallNode,
    invoke_call: InvokeCallNode,
};

const ParamNode = struct {
    key: []const u8,
    default_nodes: []const Node,
};

const ArgNode = struct {
    name: ?[]const u8,
    value_nodes: []const Node,
};

const TemplateCallNode = struct {
    name: []const u8,
    args: []const ArgNode,
};

const InvokeCallNode = struct {
    module_name: []const u8,
    function_name: []const u8,
    args: []const ArgNode,
};

const ParseTemplateError = std.mem.Allocator.Error || error{
    UnbalancedTemplate,
    UnsupportedTemplateForm,
};

const TemplateInfo = struct {
    key: []const u8,
    source: []const u8,
    nodes: []const Node = &.{},
    parse_failed: bool = false,
    class: CompileClass = .unsupported,
    class_state: enum { unresolved, resolving, resolved } = .unresolved,
    fn_ident: []const u8 = "",
};

const ModuleWrapper = struct {
    module_name: []const u8,
    function_name: []const u8,
    source: []const u8,
    fn_ident: []const u8,
};

fn compileTemplateRuntimeAlloc(
    allocator: std.mem.Allocator,
    reachable_templates: []const []const u8,
    sources: *const lua.TemplateSources,
) ![]u8 {
    var templates = try allocator.alloc(TemplateInfo, reachable_templates.len);
    errdefer allocator.free(templates);

    var template_indexes = std.StringHashMap(usize).init(allocator);
    defer template_indexes.deinit();

    for (reachable_templates, 0..) |key, idx| {
        const duped_key = try allocator.dupe(u8, key);
        templates[idx] = .{
            .key = duped_key,
            .source = sources.template_sources.get(key) orelse "",
            .fn_ident = try templateFnIdentAlloc(allocator, key, idx),
        };
        try template_indexes.put(duped_key, idx);
    }

    for (templates) |*template| {
        if (template.source.len == 0) {
            template.parse_failed = true;
            continue;
        }
        template.nodes = parseTemplateSourceAlloc(allocator, template.source) catch {
            template.parse_failed = true;
            continue;
        };
    }

    for (templates, 0..) |_, idx| _ = resolveTemplateClass(templates, &template_indexes, idx);

    var wrappers: std.ArrayList(ModuleWrapper) = .empty;
    defer wrappers.deinit(allocator);
    var wrapper_indexes = std.StringHashMap([]const u8).init(allocator);
    defer wrapper_indexes.deinit();

    for (templates) |template| {
        if (template.class != .compiled) continue;
        try collectModuleWrappers(allocator, &wrappers, &wrapper_indexes, sources, template.nodes);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("// Generated by tools/template_codegen.zig\nconst std = @import(\"std\");\nconst support = @import(");
    try appendZigStringLiteral(writer, support_import);
    try writer.writeAll(");\n\npub const TemplateClass = support.TemplateClass;\n\n");

    for (wrappers.items) |wrapper| try emitModuleWrapper(writer, wrapper);
    for (templates) |template| {
        if (template.class != .compiled) continue;
        try emitTemplateFunction(allocator, writer, templates, &template_indexes, &wrapper_indexes, template);
    }

    try emitClassifier(writer, templates);
    try emitDispatcher(writer, templates);
    return out.toOwnedSlice();
}

fn emitClassifier(writer: *std.Io.Writer, templates: []const TemplateInfo) !void {
    try writer.writeAll(
        \\
        \\pub fn classifyTemplate(name: []const u8) ?TemplateClass {
        \\
    );
    for (templates) |template| {
        try writer.writeAll("    if (support.templateNameEquals(name, ");
        try appendZigStringLiteral(writer, template.key);
        try writer.writeAll(")) return .");
        try writer.writeAll(switch (template.class) {
            .metadata_only => "metadata_only",
            .compiled => "compiled",
            .unsupported => "unsupported",
        });
        try writer.writeAll(";\n");
    }
    try writer.writeAll(
        \\    return null;
        \\}
        \\
    );
}

fn emitDispatcher(writer: *std.Io.Writer, templates: []const TemplateInfo) !void {
    try writer.writeAll(
        \\pub fn renderTemplateByName(
        \\    out: *std.ArrayList(u8),
        \\    allocator: std.mem.Allocator,
        \\    name: []const u8,
        \\    args: *const support.TemplateArgs,
        \\) !bool {
        \\
    );
    for (templates) |template| {
        if (template.class != .compiled) continue;
        try writer.writeAll("    if (support.templateNameEquals(name, ");
        try appendZigStringLiteral(writer, template.key);
        try writer.writeAll(")) {\n        try ");
        try writer.writeAll(template.fn_ident);
        try writer.writeAll("(out, allocator, args);\n        return true;\n    }\n");
    }
    try writer.writeAll(
        \\    return false;
        \\}
        \\
    );
}

fn emitModuleWrapper(writer: *std.Io.Writer, wrapper: ModuleWrapper) !void {
    try writer.writeAll("fn ");
    try writer.writeAll(wrapper.fn_ident);
    try writer.writeAll(
        \\(
        \\    out: *std.ArrayList(u8),
        \\    allocator: std.mem.Allocator,
        \\    args: *const support.TemplateArgs,
        \\) !void {
        \\    try support.invokeModuleFunction(out, allocator, 
    );
    try appendZigStringLiteral(writer, wrapper.source);
    try writer.writeAll(", ");
    try appendZigStringLiteral(writer, wrapper.function_name);
    try writer.writeAll(", args);\n}\n\n");
}

fn emitTemplateFunction(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    wrapper_indexes: *const std.StringHashMap([]const u8),
    template: TemplateInfo,
) anyerror!void {
    try writer.writeAll("fn ");
    try writer.writeAll(template.fn_ident);
    try writer.writeAll(
        \\(
        \\    out: *std.ArrayList(u8),
        \\    allocator: std.mem.Allocator,
        \\    args: *const support.TemplateArgs,
        \\) !void {
        \\
    );
    try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, template.nodes, "out", "args", 1);
    try writer.writeAll("}\n\n");
}

fn emitNodes(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    wrapper_indexes: *const std.StringHashMap([]const u8),
    nodes: []const Node,
    out_name: []const u8,
    args_name: []const u8,
    indent: usize,
) anyerror!void {
    for (nodes) |node| switch (node) {
        .text => |text| {
            if (!hasVisibleText(text)) continue;
            try writeIndent(writer, indent);
            try writer.writeAll("try support.appendText(");
            try writer.writeAll(out_name);
            try writer.writeAll(", allocator, ");
            try appendZigStringLiteral(writer, text);
            try writer.writeAll(");\n");
        },
        .param => |param| {
            try writeIndent(writer, indent);
            try writer.writeAll("if (");
            try writer.writeAll(args_name);
            try writer.writeAll(".paramValue(");
            try appendZigStringLiteral(writer, param.key);
            try writer.writeAll(")) |value| {\n");
            try writeIndent(writer, indent + 1);
            try writer.writeAll("try support.appendText(");
            try writer.writeAll(out_name);
            try writer.writeAll(", allocator, ");
            try writer.writeAll("value);\n");
            try writeIndent(writer, indent);
            try writer.writeAll("} else {\n");
            try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, param.default_nodes, out_name, args_name, indent + 1);
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .template_call => |call| {
            const callee_index = template_indexes.get(call.name) orelse continue;
            if (templates[callee_index].class == .metadata_only) continue;
            if (templates[callee_index].class != .compiled) continue;
            try emitNestedCall(allocator, writer, templates[callee_index].fn_ident, templates, template_indexes, wrapper_indexes, call.args, out_name, args_name, indent);
        },
        .invoke_call => |call| {
            const wrapper_key = try moduleWrapperKeyAlloc(allocator, call.module_name, call.function_name);
            defer allocator.free(wrapper_key);
            const wrapper_ident = wrapper_indexes.get(wrapper_key) orelse continue;
            try emitNestedCall(allocator, writer, wrapper_ident, templates, template_indexes, wrapper_indexes, call.args, out_name, args_name, indent);
        },
    };
}

fn emitNestedCall(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    callee_ident: []const u8,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    wrapper_indexes: *const std.StringHashMap([]const u8),
    args: []const ArgNode,
    out_name: []const u8,
    parent_args_name: []const u8,
    indent: usize,
) anyerror!void {
    try writeIndent(writer, indent);
    try writer.writeAll("{\n");
    try writeIndent(writer, indent + 1);
    try writer.writeAll("var child_builder: support.TemplateArgsBuilder = .{};\n");
    try writeIndent(writer, indent + 1);
    try writer.writeAll("defer child_builder.deinit(allocator);\n");
    for (args) |arg| {
        try writeIndent(writer, indent + 1);
        try writer.writeAll("var value_buf: std.ArrayList(u8) = .empty;\n");
        try writeIndent(writer, indent + 1);
        try writer.writeAll("defer value_buf.deinit(allocator);\n");
        try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, arg.value_nodes, "&value_buf", parent_args_name, indent + 1);
        try writeIndent(writer, indent + 1);
        if (arg.name) |name| {
            try writer.writeAll("try child_builder.addNamedOwned(allocator, ");
            try appendZigStringLiteral(writer, name);
            try writer.writeAll(", value_buf.items);\n");
        } else {
            try writer.writeAll("try child_builder.addPositionalOwned(allocator, value_buf.items);\n");
        }
    }
    try writeIndent(writer, indent + 1);
    try writer.writeAll("var child_args = try child_builder.buildOwned(allocator);\n");
    try writeIndent(writer, indent + 1);
    try writer.writeAll("defer child_args.deinit(allocator);\n");
    try writeIndent(writer, indent + 1);
    try writer.writeAll("try ");
    try writer.writeAll(callee_ident);
    try writer.writeAll("(");
    try writer.writeAll(out_name);
    try writer.writeAll(", allocator, &child_args);\n");
    try writeIndent(writer, indent);
    try writer.writeAll("}\n");
}

fn collectModuleWrappers(
    allocator: std.mem.Allocator,
    wrappers: *std.ArrayList(ModuleWrapper),
    wrapper_indexes: *std.StringHashMap([]const u8),
    sources: *const lua.TemplateSources,
    nodes: []const Node,
) !void {
    for (nodes) |node| switch (node) {
        .text, .param => {},
        .template_call => |call| for (call.args) |arg| try collectModuleWrappers(allocator, wrappers, wrapper_indexes, sources, arg.value_nodes),
        .invoke_call => |call| {
            const module_key = try lua.canonicalModuleNameAlloc(allocator, call.module_name);
            defer allocator.free(module_key);
            const fn_key = try moduleWrapperKeyAlloc(allocator, module_key, call.function_name);
            defer allocator.free(fn_key);
            if (wrapper_indexes.contains(fn_key)) continue;
            const source = sources.module_sources.get(module_key) orelse "";
            const fn_ident = try wrapperFnIdentAlloc(allocator, module_key, call.function_name, wrappers.items.len);
            try wrappers.append(allocator, .{
                .module_name = try allocator.dupe(u8, module_key),
                .function_name = try allocator.dupe(u8, call.function_name),
                .source = try allocator.dupe(u8, source),
                .fn_ident = fn_ident,
            });
            try wrapper_indexes.put(try allocator.dupe(u8, fn_key), fn_ident);
            for (call.args) |arg| try collectModuleWrappers(allocator, wrappers, wrapper_indexes, sources, arg.value_nodes);
        },
    };
}

fn resolveTemplateClass(
    templates: []TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    index: usize,
) CompileClass {
    if (templates[index].class_state == .resolved) return templates[index].class;
    if (templates[index].class_state == .resolving) return .compiled;
    templates[index].class_state = .resolving;

    var class: CompileClass = if (templates[index].parse_failed) .unsupported else .metadata_only;
    if (!templates[index].parse_failed) {
        var saw_visible_output = false;
        for (templates[index].nodes) |node| {
            if (nodeIsUnsupported(templates, template_indexes, node)) {
                class = .unsupported;
                break;
            }
            if (nodeContributesVisibleOutput(templates, template_indexes, node)) {
                saw_visible_output = true;
            }
        }
        if (class != .unsupported and saw_visible_output) class = .compiled;
    }

    templates[index].class = class;
    templates[index].class_state = .resolved;
    return class;
}

fn nodeContributesVisibleOutput(
    templates: []TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    node: Node,
) bool {
    return switch (node) {
        .text => |text| hasVisibleText(text),
        .param => true,
        .invoke_call => true,
        .template_call => |call| blk: {
            const callee_index = template_indexes.get(call.name) orelse break :blk true;
            break :blk resolveTemplateClass(templates, template_indexes, callee_index) == .compiled;
        },
    };
}

fn nodeIsUnsupported(
    templates: []TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    node: Node,
) bool {
    return switch (node) {
        .text, .param, .invoke_call => false,
        .template_call => |call| blk: {
            const callee_index = template_indexes.get(call.name) orelse break :blk true;
            break :blk resolveTemplateClass(templates, template_indexes, callee_index) == .unsupported;
        },
    };
}

fn parseTemplateSourceAlloc(allocator: std.mem.Allocator, source: []const u8) ParseTemplateError![]const Node {
    var cursor: usize = 0;
    return parseNodesAlloc(allocator, source, &cursor, null);
}

fn parseNodesAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    cursor: *usize,
    terminator: ?[]const u8,
) ParseTemplateError![]const Node {
    var nodes: std.ArrayList(Node) = .empty;
    errdefer nodes.deinit(allocator);

    var text_start = cursor.*;
    while (cursor.* < input.len) {
        if (terminator) |end_marker| {
            if (startsWithAt(input, cursor.*, end_marker)) break;
        }
        if (startsWithAt(input, cursor.*, "<!--")) {
            try appendTextNode(allocator, &nodes, input[text_start..cursor.*]);
            cursor.* = skipUntil(input, cursor.* + 4, "-->") orelse input.len;
            text_start = cursor.*;
            continue;
        }
        if (matchSkippableTag(input[cursor.*..])) |tag_len| {
            try appendTextNode(allocator, &nodes, input[text_start..cursor.*]);
            cursor.* += tag_len;
            text_start = cursor.*;
            continue;
        }
        if (startsWithCategoryLink(input, cursor.*)) {
            try appendTextNode(allocator, &nodes, input[text_start..cursor.*]);
            cursor.* = skipBalancedLink(input, cursor.*) orelse input.len;
            text_start = cursor.*;
            continue;
        }
        if (startsWithAt(input, cursor.*, "{{{")) {
            try appendTextNode(allocator, &nodes, input[text_start..cursor.*]);
            const end = findParamEnd(input, cursor.*) orelse return error.UnbalancedTemplate;
            const body = input[cursor.* + 3 .. end];
            try nodes.append(allocator, .{ .param = try parseParamNodeAlloc(allocator, body) });
            cursor.* = end + 3;
            text_start = cursor.*;
            continue;
        }
        if (startsWithAt(input, cursor.*, "{{")) {
            try appendTextNode(allocator, &nodes, input[text_start..cursor.*]);
            const end = findTemplateEnd(input, cursor.*) orelse return error.UnbalancedTemplate;
            const body = input[cursor.* + 2 .. end];
            try nodes.append(allocator, try parseCallNodeAlloc(allocator, body));
            cursor.* = end + 2;
            text_start = cursor.*;
            continue;
        }
        cursor.* += 1;
    }

    try appendTextNode(allocator, &nodes, input[text_start..cursor.*]);
    return nodes.toOwnedSlice(allocator);
}

fn parseParamNodeAlloc(allocator: std.mem.Allocator, body: []const u8) ParseTemplateError!ParamNode {
    var parts = try splitTopLevelAlloc(allocator, body, '|');
    defer parts.deinit(allocator);
    if (parts.items.len == 0) return .{ .key = "", .default_nodes = &.{} };

    const key = try allocator.dupe(u8, trimWikiWhitespace(parts.items[0]));
    const default_nodes = if (parts.items.len >= 2) blk: {
        var default_cursor: usize = 0;
        break :blk try parseNodesAlloc(allocator, parts.items[1], &default_cursor, null);
    } else &.{};
    return .{
        .key = key,
        .default_nodes = default_nodes,
    };
}

fn parseCallNodeAlloc(allocator: std.mem.Allocator, body: []const u8) ParseTemplateError!Node {
    var parts = try splitTopLevelAlloc(allocator, body, '|');
    defer parts.deinit(allocator);
    if (parts.items.len == 0) return .{ .text = "" };

    const raw_name = trimWikiWhitespace(parts.items[0]);
    if (startsWithInvoke(raw_name)) {
        return .{ .invoke_call = try parseInvokeNodeAlloc(allocator, raw_name, parts.items[1..]) };
    }
    if (raw_name.len == 0 or raw_name[0] == '#') return error.UnsupportedTemplateForm;

    const canonical_name = try lua.canonicalTemplateNameAlloc(allocator, raw_name);
    const args = try parseArgNodesAlloc(allocator, parts.items[1..]);
    return .{
        .template_call = .{
            .name = canonical_name,
            .args = args,
        },
    };
}

fn parseInvokeNodeAlloc(allocator: std.mem.Allocator, raw_name: []const u8, arg_segments: []const []const u8) ParseTemplateError!InvokeCallNode {
    const trimmed = trimWikiWhitespace(raw_name["#invoke:".len..]);
    const module_name = try lua.canonicalModuleNameAlloc(allocator, trimmed);
    const args = try parseArgNodesAlloc(allocator, arg_segments);
    const function_name = if (args.len != 0 and args[0].name == null) try flattenArgValueAlloc(allocator, args[0].value_nodes) else try allocator.dupe(u8, "");

    return .{
        .module_name = module_name,
        .function_name = function_name,
        .args = if (args.len == 0) args else args[1..],
    };
}

fn parseArgNodesAlloc(allocator: std.mem.Allocator, segments: []const []const u8) ParseTemplateError![]const ArgNode {
    var args: std.ArrayList(ArgNode) = .empty;
    errdefer args.deinit(allocator);

    for (segments) |segment| {
        if (topLevelEquals(segment)) |equals| {
            const key = try allocator.dupe(u8, trimWikiWhitespace(segment[0..equals]));
            const value_raw = segment[equals + 1 ..];
            var cursor: usize = 0;
            const value_nodes = try parseNodesAlloc(allocator, value_raw, &cursor, null);
            try args.append(allocator, .{ .name = key, .value_nodes = value_nodes });
        } else {
            var cursor: usize = 0;
            const value_nodes = try parseNodesAlloc(allocator, segment, &cursor, null);
            try args.append(allocator, .{ .name = null, .value_nodes = value_nodes });
        }
    }
    return args.toOwnedSlice(allocator);
}

fn flattenArgValueAlloc(allocator: std.mem.Allocator, nodes: []const Node) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (nodes) |node| switch (node) {
        .text => |text| try out.appendSlice(allocator, trimWikiWhitespace(text)),
        .param => |param| try out.appendSlice(allocator, param.key),
        else => {},
    };
    return out.toOwnedSlice(allocator);
}

fn appendTextNode(allocator: std.mem.Allocator, nodes: *std.ArrayList(Node), text: []const u8) !void {
    if (text.len == 0) return;
    const trimmed_magic = trimWikiWhitespace(text);
    if (trimmed_magic.len != 0 and std.mem.startsWith(u8, trimmed_magic, "__") and std.mem.endsWith(u8, trimmed_magic, "__")) return;
    try nodes.append(allocator, .{ .text = try allocator.dupe(u8, text) });
}

fn hasVisibleText(text: []const u8) bool {
    const trimmed = trimWikiWhitespace(text);
    return trimmed.len != 0 and !(std.mem.startsWith(u8, trimmed, "__") and std.mem.endsWith(u8, trimmed, "__"));
}

fn startsWithInvoke(name: []const u8) bool {
    return startsWithAtIgnoreCase(name, 0, "#invoke:");
}

fn startsWithCategoryLink(input: []const u8, index: usize) bool {
    return startsWithAtIgnoreCase(input, index, "[[category:") or startsWithAtIgnoreCase(input, index, "[[:category:");
}

fn skipBalancedLink(input: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i + 2 <= input.len) {
        if (startsWithAt(input, i, "[[")) {
            depth += 1;
            i += 2;
            continue;
        }
        if (startsWithAt(input, i, "]]")) {
            if (depth == 0) return null;
            depth -= 1;
            i += 2;
            if (depth == 0) return i;
            continue;
        }
        i += 1;
    }
    return null;
}

fn findTemplateEnd(input: []const u8, start: usize) ?usize {
    var templates: usize = 1;
    var params: usize = 0;
    var i = start + 2;
    while (i < input.len) {
        if (startsWithAt(input, i, "{{{")) {
            params += 1;
            i += 3;
            continue;
        }
        if (startsWithAt(input, i, "}}}")) {
            if (params != 0) params -= 1;
            i += 3;
            continue;
        }
        if (startsWithAt(input, i, "{{")) {
            templates += 1;
            i += 2;
            continue;
        }
        if (startsWithAt(input, i, "}}")) {
            templates -= 1;
            if (templates == 0 and params == 0) return i;
            i += 2;
            continue;
        }
        i += 1;
    }
    return null;
}

fn findParamEnd(input: []const u8, start: usize) ?usize {
    var templates: usize = 0;
    var params: usize = 1;
    var i = start + 3;
    while (i < input.len) {
        if (startsWithAt(input, i, "{{{")) {
            params += 1;
            i += 3;
            continue;
        }
        if (startsWithAt(input, i, "}}}")) {
            params -= 1;
            if (params == 0 and templates == 0) return i;
            i += 3;
            continue;
        }
        if (startsWithAt(input, i, "{{")) {
            templates += 1;
            i += 2;
            continue;
        }
        if (startsWithAt(input, i, "}}")) {
            if (templates != 0) templates -= 1;
            i += 2;
            continue;
        }
        i += 1;
    }
    return null;
}

fn splitTopLevelAlloc(allocator: std.mem.Allocator, input: []const u8, delim: u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var start: usize = 0;
    var templates: usize = 0;
    var params: usize = 0;
    var links: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (startsWithAt(input, i, "{{{")) {
            params += 1;
            i += 2;
            continue;
        }
        if (startsWithAt(input, i, "}}}")) {
            if (params != 0) params -= 1;
            i += 2;
            continue;
        }
        if (startsWithAt(input, i, "{{")) {
            templates += 1;
            i += 1;
            continue;
        }
        if (startsWithAt(input, i, "}}")) {
            if (templates != 0) templates -= 1;
            i += 1;
            continue;
        }
        if (startsWithAt(input, i, "[[")) {
            links += 1;
            i += 1;
            continue;
        }
        if (startsWithAt(input, i, "]]")) {
            if (links != 0) links -= 1;
            i += 1;
            continue;
        }
        if (input[i] == delim and templates == 0 and params == 0 and links == 0) {
            try out.append(allocator, input[start..i]);
            start = i + 1;
        }
    }
    try out.append(allocator, input[start..]);
    return out;
}

fn matchSkippableTag(source: []const u8) ?usize {
    inline for ([_][]const u8{
        "<includeonly>", "</includeonly>",
        "<onlyinclude>", "</onlyinclude>",
        "<noinclude/>",
        "<onlyinclude/>",
    }) |tag| {
        if (startsWithAtIgnoreCase(source, 0, tag)) return tag.len;
    }

    if (startsWithAtIgnoreCase(source, 0, "<noinclude")) {
        const start_end = std.mem.indexOfScalar(u8, source, '>') orelse return source.len;
        if (start_end > 0 and source[start_end - 1] == '/') return start_end + 1;
        return skipUntil(source, start_end + 1, "</noinclude>") orelse source.len;
    }
    if (startsWithAtIgnoreCase(source, 0, "<templatedata")) {
        const start_end = std.mem.indexOfScalar(u8, source, '>') orelse return source.len;
        return skipUntil(source, start_end + 1, "</templatedata>") orelse source.len;
    }
    return null;
}

fn skipUntil(source: []const u8, start: usize, needle: []const u8) ?usize {
    const found = std.mem.indexOfPos(u8, source, start, needle) orelse return null;
    return found + needle.len;
}

fn startsWithAt(input: []const u8, index: usize, needle: []const u8) bool {
    return index + needle.len <= input.len and std.mem.eql(u8, input[index .. index + needle.len], needle);
}

fn startsWithAtIgnoreCase(input: []const u8, index: usize, needle: []const u8) bool {
    if (index + needle.len > input.len) return false;
    for (needle, 0..) |byte, offset| {
        if (std.ascii.toLower(input[index + offset]) != std.ascii.toLower(byte)) return false;
    }
    return true;
}

fn topLevelEquals(segment: []const u8) ?usize {
    var templates: usize = 0;
    var params: usize = 0;
    var links: usize = 0;
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        if (startsWithAt(segment, i, "{{{")) {
            params += 1;
            i += 2;
            continue;
        }
        if (startsWithAt(segment, i, "}}}")) {
            if (params != 0) params -= 1;
            i += 2;
            continue;
        }
        if (startsWithAt(segment, i, "{{")) {
            templates += 1;
            i += 1;
            continue;
        }
        if (startsWithAt(segment, i, "}}")) {
            if (templates != 0) templates -= 1;
            i += 1;
            continue;
        }
        if (startsWithAt(segment, i, "[[")) {
            links += 1;
            i += 1;
            continue;
        }
        if (startsWithAt(segment, i, "]]")) {
            if (links != 0) links -= 1;
            i += 1;
            continue;
        }
        if (segment[i] == '=' and templates == 0 and params == 0 and links == 0) return i;
    }
    return null;
}

fn trimWikiWhitespace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

fn templateFnIdentAlloc(allocator: std.mem.Allocator, key: []const u8, index: usize) ![]u8 {
    return sanitizeIdentAlloc(allocator, "tpl_", key, index);
}

fn wrapperFnIdentAlloc(allocator: std.mem.Allocator, module_name: []const u8, function_name: []const u8, index: usize) ![]u8 {
    const joined = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ module_name, function_name });
    defer allocator.free(joined);
    return sanitizeIdentAlloc(allocator, "invoke_", joined, index);
}

fn sanitizeIdentAlloc(allocator: std.mem.Allocator, prefix: []const u8, raw: []const u8, index: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, prefix);
    for (raw) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            try out.append(allocator, std.ascii.toLower(byte));
        } else {
            try out.append(allocator, '_');
        }
    }
    var suffix_buf: [32]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&suffix_buf, "_{d}", .{index});
    try out.appendSlice(allocator, suffix);
    return out.toOwnedSlice(allocator);
}

fn moduleWrapperKeyAlloc(allocator: std.mem.Allocator, module_name: []const u8, function_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}|{s}", .{ module_name, function_name });
}

fn appendZigStringLiteral(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => {
            if (std.ascii.isPrint(byte)) {
                try writer.writeByte(byte);
            } else {
                try writer.print("\\x{X:0>2}", .{byte});
            }
        },
    };
    try writer.writeByte('"');
}

fn writeIndent(writer: *std.Io.Writer, indent: usize) !void {
    for (0..indent) |_| try writer.writeAll("    ");
}

const static_bin_template_names = [_][]const u8{
    "en-noun",
    "en-verb",
    "en-adj",
    "en-proper noun",
    "head",
    "plural of",
    "infl of",
    "lb",
    "IPA",
    "audio",
    "rhymes",
    "col",
    "col2",
    "col3",
    "col4",
    "col5",
};

const MappedReadOnlyFile = struct {
    mapping: []align(std.heap.page_size_min) const u8,

    fn deinit(self: *MappedReadOnlyFile) void {
        std.posix.munmap(self.mapping);
        self.* = undefined;
    }
};

fn loadDbTemplateNamesAlloc(allocator: std.mem.Allocator, db_path: []const u8) ![]const []const u8 {
    var mapped = try mmapReadOnlyPath(db_path);
    defer mapped.deinit();

    const inspected = try decoder.format.inspectDictionary(mapped.mapping);
    const mapping_start: usize = @intCast(inspected.layout.mappings_offset);
    const mapping_end: usize = @intCast(inspected.layout.mappings_offset + inspected.layout.mappings_len);
    const mapping_blob = mapped.mapping[mapping_start..mapping_end];

    var mappings = try decoder.format.parseCompactMappingsAlloc(allocator, mapping_blob);
    defer mappings.deinit(allocator);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var covered: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = covered.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        covered.deinit(allocator);
    }
    try compact_pattern_seed.seedCoveredTemplateNames(allocator, &covered);

    var covered_it = covered.iterator();
    while (covered_it.next()) |entry| try names.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
    for (mappings.line_templates) |entry| try names.append(allocator, try allocator.dupe(u8, entry.name));
    for (mappings.translation_templates) |entry| try names.append(allocator, try allocator.dupe(u8, entry.name));
    for (static_bin_template_names) |name| try names.append(allocator, try allocator.dupe(u8, name));
    return names.toOwnedSlice(allocator);
}

fn freeOwnedStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn mmapReadOnlyPath(path: []const u8) !MappedReadOnlyFile {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0);

    const io = std.Options.debug_io;
    var file: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    if (len == 0) return error.FileTooBig;

    const mapping = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    return .{ .mapping = mapping };
}

test "template compiler classifies metadata-only templates by nested nop closure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sources = lua.TemplateSources{
        .template_sources = std.StringHashMap([]const u8).init(allocator),
        .module_sources = std.StringHashMap([]const u8).init(allocator),
    };
    defer sources.deinit(allocator);
    try sources.template_sources.put(try allocator.dupe(u8, "meta"), try allocator.dupe(u8, "__NOTOC__"));
    try sources.template_sources.put(try allocator.dupe(u8, "outer"), try allocator.dupe(u8, "{{meta}}"));

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{ "meta", "outer" }, &sources);
    try std.testing.expect(std.mem.indexOf(u8, generated, "return .metadata_only") != null);
}

test "template compiler emits direct nested template calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sources = lua.TemplateSources{
        .template_sources = std.StringHashMap([]const u8).init(allocator),
        .module_sources = std.StringHashMap([]const u8).init(allocator),
    };
    defer sources.deinit(allocator);
    try sources.template_sources.put(try allocator.dupe(u8, "inner"), try allocator.dupe(u8, "hello"));
    try sources.template_sources.put(try allocator.dupe(u8, "outer"), try allocator.dupe(u8, "before {{inner}} after"));

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{ "inner", "outer" }, &sources);
    try std.testing.expect(std.mem.indexOf(u8, generated, "fn tpl_inner_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "fn tpl_outer_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "try tpl_inner_0(out, allocator, &child_args);") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "renderTemplateByName") != null);
}

test "template compiler strips metadata and emits nop for pure metadata template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sources = lua.TemplateSources{
        .template_sources = std.StringHashMap([]const u8).init(allocator),
        .module_sources = std.StringHashMap([]const u8).init(allocator),
    };
    defer sources.deinit(allocator);
    try sources.template_sources.put(
        try allocator.dupe(u8, "meta-only"),
        try allocator.dupe(u8, "<noinclude>doc</noinclude>[[Category:test]]__NOTOC__"),
    );

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{ "meta-only" }, &sources);
    try std.testing.expect(std.mem.indexOf(u8, generated, "return .metadata_only") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "fn tpl_meta_only_0") == null);
}

test "template compiler emits direct invoke wrappers for nested module calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sources = lua.TemplateSources{
        .template_sources = std.StringHashMap([]const u8).init(allocator),
        .module_sources = std.StringHashMap([]const u8).init(allocator),
    };
    defer sources.deinit(allocator);
    try sources.template_sources.put(
        try allocator.dupe(u8, "wrap"),
        try allocator.dupe(u8, "pre {{#invoke:foo|bar|{{{1|x}}}}} post"),
    );
    try sources.module_sources.put(
        try allocator.dupe(u8, "foo"),
        try allocator.dupe(u8, "return { bar = function(frame) return frame.args[1] or '' end }"),
    );

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{ "wrap" }, &sources);
    try std.testing.expect(std.mem.indexOf(u8, generated, "fn invoke_foo_bar_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "try invoke_foo_bar_0(out, allocator, &child_args);") != null);
}

test "template compiler marks unresolved nested templates unsupported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sources = lua.TemplateSources{
        .template_sources = std.StringHashMap([]const u8).init(allocator),
        .module_sources = std.StringHashMap([]const u8).init(allocator),
    };
    defer sources.deinit(allocator);
    try sources.template_sources.put(
        try allocator.dupe(u8, "outer"),
        try allocator.dupe(u8, "before {{missing-template}} after"),
    );

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{ "outer" }, &sources);
    try std.testing.expect(std.mem.indexOf(u8, generated, "return .unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "fn tpl_outer_0") == null);
}
