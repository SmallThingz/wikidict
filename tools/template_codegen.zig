const std = @import("std");
const lua = @import("lua");
const decoder = @import("decoder");
const compact_pattern_seed = @import("compact_pattern_seed");
const required_path = @import("required_path");

const support_import = "template_compiler_support";
const max_generated_template_source_bytes = 16 * 1024;
const max_generated_module_source_bytes = 64 * 1024;
const max_generated_module_zig_bytes = 512 * 1024;

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

    const had_audit_failures = report.unresolved_templates.len != 0 or
        report.missing_modules.len != 0 or
        report.compiled_failed.len != 0 or
        report.emitted_inconsistent.len != 0;
    if (had_audit_failures) {
        try printDependencyFailures(allocator, report);
    }

    const compiled = try compileTemplateRuntimeAlloc(allocator, report.reachable_templates, &sources);
    defer {
        allocator.free(compiled.source);
        for (compiled.unsupported) |entry| allocator.free(entry.reason);
        allocator.free(compiled.unsupported);
    }
    if (compiled.unsupported.len != 0) {
        try printUnsupportedTemplates(allocator, compiled.unsupported);
        if (options.template_name) |name| {
            const source = sources.template_sources.get(name) orelse "";
            if (source.len != 0) {
                std.debug.print("--- template source: {s} ---\n{s}\n", .{ name, source });
            }
        }
    }

    var file = try std.Io.Dir.cwd().createFile(init.io, options.output_path, .{ .truncate = true });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, compiled.source);

    std.debug.print(
        "template compiler: roots={d} reachable={d} compiled={d} metadata_only={d} unsupported={d} unresolved={d} missing_modules={d} output={s}\n",
        .{
            roots.len,
            report.reachable_templates.len,
            compiled.compiled_count,
            compiled.metadata_only_count,
            compiled.unsupported.len,
            report.unresolved_templates.len,
            report.missing_modules.len,
            options.output_path,
        },
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
    parser_func: ParserFunctionNode,
};

const ParamNode = struct {
    key: []const u8,
    default_nodes: []const Node,
};

const ArgNode = struct {
    name: ?[]const u8,
    name_nodes: []const Node = &.{},
    name_is_dynamic: bool = false,
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

const ParserFunctionKind = enum {
    displaytitle,
    if_,
    ifeq,
    switch_,
    tag,
    lc,
    uc,
    lcfirst,
    ucfirst,
    formatnum,
    anchorencode,
    padleft,
    padright,
    currentday,
    currentmonth,
    currentmonthname,
    currentyear,
    pagename,
    fullpagename,
    basepagename,
    subpagename,
    namespace,
    namespacenumber,
    talkpagename,
    wikimedialanguage,
};

const ParserFunctionNode = struct {
    kind: ParserFunctionKind,
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
    parse_error: ?ParseFailureKind = null,
    source_too_large: bool = false,
    class: CompileClass = .unsupported,
    class_state: enum { unresolved, resolving, resolved } = .unresolved,
    fn_ident: []const u8 = "",
};

const ParseFailureKind = enum {
    unbalanced_template,
    unsupported_template_form,
    oom,
};

const ModuleWrapper = struct {
    module_name: []const u8,
    function_name: []const u8,
    module_ident: []const u8,
    fn_ident: []const u8,
};

const ModuleInfo = struct {
    key: []const u8,
    struct_ident: []const u8,
    zig_source: []const u8 = "",
    emit_failed: bool = false,
    too_large: bool = false,
};

const DispatchTemplate = struct {
    normalized: []const u8,
    class: CompileClass,
    fn_ident: ?[]const u8,
};

const UnsupportedTemplate = struct {
    key: []const u8,
    reason: []const u8,
};

const CompileRuntimeResult = struct {
    source: []u8,
    compiled_count: usize,
    metadata_only_count: usize,
    unsupported: []const UnsupportedTemplate,
};

fn normalizeTemplateLookupNameAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (name) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '_') continue;
        try out.append(allocator, std.ascii.toLower(byte));
    }
    return try out.toOwnedSlice(allocator);
}

fn buildDispatchTemplatesAlloc(
    allocator: std.mem.Allocator,
    templates: []const TemplateInfo,
) ![]DispatchTemplate {
    var entries: std.ArrayList(DispatchTemplate) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.normalized);
        entries.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (templates) |template| {
        const normalized = try normalizeTemplateLookupNameAlloc(allocator, template.key);
        errdefer allocator.free(normalized);
        if (seen.contains(normalized)) {
            allocator.free(normalized);
            continue;
        }
        try seen.put(normalized, {});
        try entries.append(allocator, .{
            .normalized = normalized,
            .class = template.class,
            .fn_ident = if (template.class == .compiled) template.fn_ident else null,
        });
    }

    std.mem.sort(DispatchTemplate, entries.items, {}, struct {
        fn lessThan(_: void, lhs: DispatchTemplate, rhs: DispatchTemplate) bool {
            return std.mem.order(u8, lhs.normalized, rhs.normalized) == .lt;
        }
    }.lessThan);
    return try entries.toOwnedSlice(allocator);
}

fn compileTemplateRuntimeAlloc(
    allocator: std.mem.Allocator,
    reachable_templates: []const []const u8,
    sources: *const lua.TemplateSources,
) !CompileRuntimeResult {
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
            template.parse_error = .unsupported_template_form;
            continue;
        }
        if (template.source.len > max_generated_template_source_bytes) {
            template.source_too_large = true;
            continue;
        }
        template.nodes = parseTemplateSourceAlloc(allocator, template.source) catch |err| {
            template.parse_error = switch (err) {
                error.UnbalancedTemplate => .unbalanced_template,
                error.UnsupportedTemplateForm => .unsupported_template_form,
                error.OutOfMemory => .oom,
            };
            continue;
        };
    }

    var modules = try buildModuleInfosAlloc(allocator, templates, sources);
    defer {
        for (modules.items) |module| allocator.free(module.key);
        for (modules.items) |module| allocator.free(module.struct_ident);
        for (modules.items) |module| allocator.free(module.zig_source);
        modules.deinit(allocator);
    }
    var module_indexes = std.StringHashMap(usize).init(allocator);
    defer module_indexes.deinit();
    for (modules.items, 0..) |module, idx| try module_indexes.put(module.key, idx);

    for (templates, 0..) |_, idx| _ = resolveTemplateClass(templates, &template_indexes, idx);
    for (templates, 0..) |*template, idx| {
        if (template.class == .unsupported) continue;
        if (templateHasUnsupportedInvoke(templates[idx].nodes, modules.items, &module_indexes)) {
            template.class = .unsupported;
        }
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (templates) |*template| {
            if (template.class == .unsupported) continue;
            if (templateDependsOnUnsupportedTemplate(template.nodes, templates, &template_indexes)) {
                template.class = .unsupported;
                changed = true;
            }
        }
    }

    var wrappers: std.ArrayList(ModuleWrapper) = .empty;
    defer wrappers.deinit(allocator);
    var wrapper_indexes = std.StringHashMap([]const u8).init(allocator);
    defer wrapper_indexes.deinit();
    const dispatch_templates = try buildDispatchTemplatesAlloc(allocator, templates);
    defer {
        for (dispatch_templates) |entry| allocator.free(entry.normalized);
        allocator.free(dispatch_templates);
    }

    for (templates) |template| {
        if (template.class != .compiled) continue;
        try collectModuleWrappers(allocator, &wrappers, &wrapper_indexes, modules.items, &module_indexes, template.nodes);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("// Generated by tools/template_codegen.zig\nconst runtime_std = @import(\"std\");\nconst support = @import(");
    try appendZigStringLiteral(writer, support_import);
    try writer.writeAll(");\n\npub const TemplateClass = support.TemplateClass;\n\n");

    for (modules.items) |module| {
        if (!moduleUsedByWrappers(module.struct_ident, wrappers.items)) continue;
        try emitGeneratedModuleStruct(writer, module);
    }
    for (wrappers.items) |wrapper| try emitModuleWrapper(writer, wrapper);
    for (templates) |template| {
        if (template.class != .compiled) continue;
        try emitTemplateFunction(allocator, writer, templates, &template_indexes, &wrapper_indexes, template);
    }

    try emitClassifier(writer, dispatch_templates);
    try emitDispatcher(writer);

    var unsupported: std.ArrayList(UnsupportedTemplate) = .empty;
    errdefer {
        for (unsupported.items) |entry| allocator.free(entry.reason);
        unsupported.deinit(allocator);
    }

    var compiled_count: usize = 0;
    var metadata_only_count: usize = 0;
    for (templates) |template| switch (template.class) {
        .compiled => compiled_count += 1,
        .metadata_only => metadata_only_count += 1,
        .unsupported => try unsupported.append(allocator, .{
            .key = template.key,
            .reason = try unsupportedReasonAlloc(allocator, template, modules.items, &module_indexes),
        }),
    };

    return .{
        .source = try out.toOwnedSlice(),
        .compiled_count = compiled_count,
        .metadata_only_count = metadata_only_count,
        .unsupported = try unsupported.toOwnedSlice(allocator),
    };
}

fn emitClassifier(writer: *std.Io.Writer, templates: []const DispatchTemplate) !void {
    try writer.writeAll(
        \\
        \\const TemplateDispatchFn = *const fn (
        \\    out: *runtime_std.ArrayList(u8),
        \\    allocator: runtime_std.mem.Allocator,
        \\    args: *const support.TemplateArgs,
        \\) anyerror!void;
        \\
        \\const TemplateDispatchEntry = struct {
        \\    normalized: []const u8,
        \\    class: TemplateClass,
        \\    render: ?TemplateDispatchFn,
        \\};
        \\
        \\const template_dispatch_entries = [_]TemplateDispatchEntry{
        \\
    );
    for (templates) |template| {
        try writer.writeAll("    .{ .normalized = ");
        try appendZigStringLiteral(writer, template.normalized);
        try writer.writeAll(", .class = .");
        try writer.writeAll(@tagName(template.class));
        try writer.writeAll(", .render = ");
        if (template.fn_ident) |fn_ident| {
            try writer.writeAll(fn_ident);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(" },\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\fn findTemplateDispatchEntry(name: []const u8) ?*const TemplateDispatchEntry {
        \\    var lo: usize = 0;
        \\    var hi: usize = template_dispatch_entries.len;
        \\    while (lo < hi) {
        \\        const mid = lo + ((hi - lo) / 2);
        \\        switch (support.compareTemplateNameToNormalized(name, template_dispatch_entries[mid].normalized)) {
        \\            .lt => hi = mid,
        \\            .gt => lo = mid + 1,
        \\            .eq => return &template_dispatch_entries[mid],
        \\        }
        \\    }
        \\    return null;
        \\}
        \\
        \\pub fn classifyTemplate(name: []const u8) ?TemplateClass {
        \\    const entry = findTemplateDispatchEntry(name) orelse return null;
        \\    return entry.class;
        \\}
        \\
    );
}

fn emitDispatcher(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\pub fn renderTemplateByName(
        \\    out: *runtime_std.ArrayList(u8),
        \\    allocator: runtime_std.mem.Allocator,
        \\    name: []const u8,
        \\    args: *const support.TemplateArgs,
        \\) !bool {
        \\    const entry = findTemplateDispatchEntry(name) orelse return false;
        \\    const render = entry.render orelse return false;
        \\    try render(out, allocator, args);
        \\    return true;
        \\}
        \\
    );
}

fn emitModuleWrapper(writer: *std.Io.Writer, wrapper: ModuleWrapper) !void {
    try writer.writeAll("fn ");
    try writer.writeAll(wrapper.fn_ident);
    try writer.writeAll(
        \\(
        \\    out: *runtime_std.ArrayList(u8),
        \\    allocator: runtime_std.mem.Allocator,
        \\    args: *const support.TemplateArgs,
        \\) !void {
        \\    try support.invokeGeneratedModuleFunction(out, allocator, 
    );
    try writer.writeAll(wrapper.module_ident);
    try writer.writeAll(".run, ");
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
    var temp_counter: usize = 0;
    try writer.writeAll("fn ");
    try writer.writeAll(template.fn_ident);
    try writer.writeAll(
        \\(
        \\    out: *runtime_std.ArrayList(u8),
        \\    allocator: runtime_std.mem.Allocator,
        \\    args: *const support.TemplateArgs,
        \\) !void {
        \\
    );
    if (!nodesUseArgs(template.nodes)) {
        try writer.writeAll("    support.touchTemplateArgs(args);\n");
    }
    try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, template.nodes, "out", "args", 1, &temp_counter);
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
    temp_counter: *usize,
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
            const static_default = try staticVisibleTextAlloc(allocator, param.default_nodes);
            defer if (static_default) |value| allocator.free(value);
            if (static_default) |default_value| {
                try writeIndent(writer, indent);
                try writer.writeAll("try support.appendResolvedParam(");
                try writer.writeAll(out_name);
                try writer.writeAll(", allocator, ");
                try writer.writeAll(args_name);
                try writer.writeAll(", ");
                try appendZigStringLiteral(writer, param.key);
                try writer.writeAll(", ");
                try appendZigStringLiteral(writer, default_value);
                try writer.writeAll(");\n");
                continue;
            }
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
            try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, param.default_nodes, out_name, args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .template_call => |call| {
            const callee_index = template_indexes.get(call.name) orelse continue;
            if (templates[callee_index].class == .metadata_only) continue;
            if (templates[callee_index].class != .compiled) continue;
            try emitNestedCall(allocator, writer, templates[callee_index].fn_ident, templates, template_indexes, wrapper_indexes, call.args, out_name, args_name, indent, temp_counter);
        },
        .invoke_call => |call| {
            const wrapper_key = try moduleWrapperKeyAlloc(allocator, call.module_name, call.function_name);
            defer allocator.free(wrapper_key);
            const wrapper_ident = wrapper_indexes.get(wrapper_key) orelse continue;
            try emitNestedCall(allocator, writer, wrapper_ident, templates, template_indexes, wrapper_indexes, call.args, out_name, args_name, indent, temp_counter);
        },
        .parser_func => |func| try emitParserFunction(allocator, writer, templates, template_indexes, wrapper_indexes, func, out_name, args_name, indent, temp_counter),
    };
}

fn nodesUseArgs(nodes: []const Node) bool {
    for (nodes) |node| switch (node) {
        .text => {},
        .param => return true,
        // Nested transclusions inherit the caller's page-title context.
        .template_call => return true,
        // Generated invoke wrappers also inherit page-title context.
        .invoke_call => return true,
        .parser_func => |func| {
            if (parserFunctionNeedsArgs(func.kind)) return true;
            for (func.args) |arg| {
                if (arg.name_is_dynamic and nodesUseArgs(arg.name_nodes)) return true;
                if (nodesUseArgs(arg.value_nodes)) return true;
            }
        },
    };
    return false;
}

const SimpleNodesExpr = union(enum) {
    literal: []const u8,
    resolved_param: struct {
        key: []const u8,
        default_value: []const u8,
    },

    fn deinit(self: SimpleNodesExpr, allocator: std.mem.Allocator) void {
        switch (self) {
            .literal => |value| allocator.free(value),
            .resolved_param => |value| allocator.free(value.default_value),
        }
    }
};

fn staticVisibleTextAlloc(allocator: std.mem.Allocator, nodes: []const Node) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (nodes) |node| switch (node) {
        .text => |text| {
            if (!hasVisibleText(text)) continue;
            try out.appendSlice(allocator, text);
        },
        else => return null,
    };
    return try out.toOwnedSlice(allocator);
}

fn simpleNodesExprAlloc(allocator: std.mem.Allocator, nodes: []const Node) !?SimpleNodesExpr {
    const literal = try staticVisibleTextAlloc(allocator, nodes);
    if (literal) |value| return .{ .literal = value };

    if (nodes.len != 1) return null;
    return switch (nodes[0]) {
        .param => |param| blk: {
            const default_value = try staticVisibleTextAlloc(allocator, param.default_nodes) orelse return null;
            break :blk .{ .resolved_param = .{
                .key = param.key,
                .default_value = default_value,
            } };
        },
        else => null,
    };
}

fn emitSimpleNodesExpr(
    writer: *std.Io.Writer,
    expr: SimpleNodesExpr,
    args_name: []const u8,
) !void {
    switch (expr) {
        .literal => |value| try appendZigStringLiteral(writer, value),
        .resolved_param => |value| {
            try writer.writeAll("(");
            try writer.writeAll(args_name);
            try writer.writeAll(".paramValue(");
            try appendZigStringLiteral(writer, value.key);
            try writer.writeAll(") orelse ");
            try appendZigStringLiteral(writer, value.default_value);
            try writer.writeAll(")");
        },
    }
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
    temp_counter: *usize,
) anyerror!void {
    const call_id = temp_counter.*;
    temp_counter.* += 1;
    try writeIndent(writer, indent);
    try writer.writeAll("{\n");
    try writeIndent(writer, indent + 1);
    try writer.print("var child_builder_{d}: support.TemplateArgsBuilder = .{{}};\n", .{call_id});
    try writeIndent(writer, indent + 1);
    try writer.print("defer child_builder_{d}.deinit(allocator);\n", .{call_id});
    for (args, 0..) |arg, arg_index| {
        const simple_value = try simpleNodesExprAlloc(allocator, arg.value_nodes);
        defer if (simple_value) |value| value.deinit(allocator);
        try writeIndent(writer, indent + 1);
        if (arg.name_is_dynamic) {
            const simple_name = try simpleNodesExprAlloc(allocator, arg.name_nodes);
            defer if (simple_name) |value| value.deinit(allocator);
            if (simple_name != null and simple_value != null) {
                try writer.print("try child_builder_{d}.addNamedBorrowed(allocator, ", .{call_id});
                try emitSimpleNodesExpr(writer, simple_name.?, parent_args_name);
                try writer.writeAll(", ");
                try emitSimpleNodesExpr(writer, simple_value.?, parent_args_name);
                try writer.writeAll(");\n");
                continue;
            }
            try writer.print("var value_buf_{d}_{d}: runtime_std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent + 1);
            try writer.print("defer value_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const value_buf_name = try std.fmt.allocPrint(allocator, "&value_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(value_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, arg.value_nodes, value_buf_name, parent_args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.print("var name_buf_{d}_{d}: runtime_std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent + 1);
            try writer.print("defer name_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const name_buf_name = try std.fmt.allocPrint(allocator, "&name_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(name_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, arg.name_nodes, name_buf_name, parent_args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.print("try child_builder_{d}.addNamedOwnedBuffers(allocator, try name_buf_{d}_{d}.toOwnedSlice(allocator), try value_buf_{d}_{d}.toOwnedSlice(allocator));\n", .{ call_id, call_id, arg_index, call_id, arg_index });
        } else if (arg.name) |name| {
            if (simple_value) |value| {
                try writer.print("try child_builder_{d}.addNamedBorrowed(allocator, ", .{call_id});
                try appendZigStringLiteral(writer, name);
                try writer.writeAll(", ");
                try emitSimpleNodesExpr(writer, value, parent_args_name);
                try writer.writeAll(");\n");
                continue;
            }
            try writer.print("var value_buf_{d}_{d}: runtime_std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent + 1);
            try writer.print("defer value_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const value_buf_name = try std.fmt.allocPrint(allocator, "&value_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(value_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, arg.value_nodes, value_buf_name, parent_args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.print("try child_builder_{d}.addNamedBuffer(allocator, ", .{call_id});
            try appendZigStringLiteral(writer, name);
            try writer.print(", try value_buf_{d}_{d}.toOwnedSlice(allocator));\n", .{ call_id, arg_index });
        } else {
            if (simple_value) |value| {
                try writer.print("try child_builder_{d}.addPositionalBorrowed(allocator, ", .{call_id});
                try emitSimpleNodesExpr(writer, value, parent_args_name);
                try writer.writeAll(");\n");
                continue;
            }
            try writer.print("var value_buf_{d}_{d}: runtime_std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent + 1);
            try writer.print("defer value_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const value_buf_name = try std.fmt.allocPrint(allocator, "&value_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(value_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, arg.value_nodes, value_buf_name, parent_args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.print("try child_builder_{d}.addPositionalBuffer(allocator, try value_buf_{d}_{d}.toOwnedSlice(allocator));\n", .{ call_id, call_id, arg_index });
        }
    }
    try writeIndent(writer, indent + 1);
    try writer.print("const child_args_{d} = child_builder_{d}.buildBorrowed(", .{ call_id, call_id });
    try writer.writeAll(parent_args_name);
    try writer.writeAll(".page_title);\n");
    try writeIndent(writer, indent + 1);
    try writer.writeAll("try ");
    try writer.writeAll(callee_ident);
    try writer.writeAll("(");
    try writer.writeAll(out_name);
    try writer.print(", allocator, &child_args_{d});\n", .{call_id});
    try writeIndent(writer, indent);
    try writer.writeAll("}\n");
}

fn allocTempLocalName(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    temp_counter: *usize,
) ![]u8 {
    const id = temp_counter.*;
    temp_counter.* += 1;
    return std.fmt.allocPrint(allocator, "{s}_{d}", .{ prefix, id });
}

fn emitParserFunction(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    wrapper_indexes: *const std.StringHashMap([]const u8),
    func: ParserFunctionNode,
    out_name: []const u8,
    args_name: []const u8,
    indent: usize,
    temp_counter: *usize,
) anyerror!void {
    switch (func.kind) {
        .displaytitle => return,
        .if_ => {
            const pf_cond_name = try allocTempLocalName(allocator, "pf_cond", temp_counter);
            defer allocator.free(pf_cond_name);
            try writeIndent(writer, indent);
            try writer.writeAll("{\n");
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, wrapper_indexes, parserArgValueNodes(func.args, 0), pf_cond_name, args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("if (support.isTruthy(");
            try writer.writeAll(pf_cond_name);
            try writer.writeAll(".items)) {\n");
            try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, parserArgValueNodes(func.args, 1), out_name, args_name, indent + 2, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("} else {\n");
            try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, parserArgValueNodes(func.args, 2), out_name, args_name, indent + 2, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("}\n");
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .ifeq => {
            const pf_lhs_name = try allocTempLocalName(allocator, "pf_lhs", temp_counter);
            defer allocator.free(pf_lhs_name);
            const pf_rhs_name = try allocTempLocalName(allocator, "pf_rhs", temp_counter);
            defer allocator.free(pf_rhs_name);
            try writeIndent(writer, indent);
            try writer.writeAll("{\n");
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, wrapper_indexes, parserArgValueNodes(func.args, 0), pf_lhs_name, args_name, indent + 1, temp_counter);
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, wrapper_indexes, parserArgValueNodes(func.args, 1), pf_rhs_name, args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("if (support.wikiTextEquals(");
            try writer.writeAll(pf_lhs_name);
            try writer.writeAll(".items, ");
            try writer.writeAll(pf_rhs_name);
            try writer.writeAll(".items)) {\n");
            try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, parserArgValueNodes(func.args, 2), out_name, args_name, indent + 2, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("} else {\n");
            try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, parserArgValueNodes(func.args, 3), out_name, args_name, indent + 2, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("}\n");
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .switch_ => try emitSwitchParserFunction(allocator, writer, templates, template_indexes, wrapper_indexes, func.args, out_name, args_name, indent, temp_counter),
        .tag => try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, parserArgValueNodes(func.args, 1), out_name, args_name, indent, temp_counter),
        .lc, .uc, .lcfirst, .ucfirst, .formatnum, .anchorencode, .padleft, .padright => {
            const pf_arg0_name = try allocTempLocalName(allocator, "pf_arg0", temp_counter);
            defer allocator.free(pf_arg0_name);
            try writeIndent(writer, indent);
            try writer.writeAll("{\n");
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, wrapper_indexes, parserArgValueNodes(func.args, 0), pf_arg0_name, args_name, indent + 1, temp_counter);
            switch (func.kind) {
                .lc => {
                    try writeIndent(writer, indent + 1);
                    try writer.writeAll("try support.appendLower(");
                    try writer.writeAll(out_name);
                    try writer.writeAll(", allocator, ");
                    try writer.writeAll(pf_arg0_name);
                    try writer.writeAll(".items);\n");
                },
                .uc => {
                    try writeIndent(writer, indent + 1);
                    try writer.writeAll("try support.appendUpper(");
                    try writer.writeAll(out_name);
                    try writer.writeAll(", allocator, ");
                    try writer.writeAll(pf_arg0_name);
                    try writer.writeAll(".items);\n");
                },
                .lcfirst => {
                    try writeIndent(writer, indent + 1);
                    try writer.writeAll("try support.appendLcFirst(");
                    try writer.writeAll(out_name);
                    try writer.writeAll(", allocator, ");
                    try writer.writeAll(pf_arg0_name);
                    try writer.writeAll(".items);\n");
                },
                .ucfirst => {
                    try writeIndent(writer, indent + 1);
                    try writer.writeAll("try support.appendUcFirst(");
                    try writer.writeAll(out_name);
                    try writer.writeAll(", allocator, ");
                    try writer.writeAll(pf_arg0_name);
                    try writer.writeAll(".items);\n");
                },
                .formatnum => {
                    try writeIndent(writer, indent + 1);
                    try writer.writeAll("try support.appendFormatNum(");
                    try writer.writeAll(out_name);
                    try writer.writeAll(", allocator, ");
                    try writer.writeAll(pf_arg0_name);
                    try writer.writeAll(".items);\n");
                },
                .anchorencode => {
                    try writeIndent(writer, indent + 1);
                    try writer.writeAll("try support.appendAnchorEncode(");
                    try writer.writeAll(out_name);
                    try writer.writeAll(", allocator, ");
                    try writer.writeAll(pf_arg0_name);
                    try writer.writeAll(".items);\n");
                },
                .padleft, .padright => {
                    const pf_width_name = try allocTempLocalName(allocator, "pf_width", temp_counter);
                    defer allocator.free(pf_width_name);
                    const pf_pad_name = try allocTempLocalName(allocator, "pf_pad", temp_counter);
                    defer allocator.free(pf_pad_name);
                    try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, wrapper_indexes, parserArgValueNodes(func.args, 1), pf_width_name, args_name, indent + 1, temp_counter);
                    try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, wrapper_indexes, parserArgValueNodes(func.args, 2), pf_pad_name, args_name, indent + 1, temp_counter);
                    try writeIndent(writer, indent + 1);
                    try writer.writeAll("const pf_width_value = runtime_std.fmt.parseUnsigned(usize, runtime_std.mem.trim(u8, ");
                    try writer.writeAll(pf_width_name);
                    try writer.writeAll(".items, \" \\t\\r\\n\"), 10) catch 0;\n");
                    try writeIndent(writer, indent + 1);
                    try writer.writeAll("try support.appendPad(");
                    try writer.writeAll(out_name);
                    try writer.writeAll(", allocator, ");
                    try writer.writeAll(pf_arg0_name);
                    try writer.writeAll(".items, pf_width_value, ");
                    try writer.writeAll(pf_pad_name);
                    try writer.writeAll(".items, .");
                    try writer.writeAll(if (func.kind == .padleft) "left" else "right");
                    try writer.writeAll(");\n");
                },
                else => unreachable,
            }
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .currentday, .currentmonth, .currentmonthname, .currentyear, .pagename, .fullpagename, .basepagename, .subpagename, .namespace, .namespacenumber, .talkpagename, .wikimedialanguage => {
            try writeIndent(writer, indent);
            try writer.writeAll("try support.appendText(");
            try writer.writeAll(out_name);
            try writer.writeAll(", allocator, ");
            switch (func.kind) {
                .currentday => try writer.writeAll("support.currentDayText()"),
                .currentmonth => try writer.writeAll("support.currentMonthText()"),
                .currentmonthname => try writer.writeAll("support.currentMonthName()"),
                .currentyear => try writer.writeAll("support.currentYearText()"),
                .pagename => {
                    try writer.writeAll("support.pageName(");
                    try writer.writeAll(args_name);
                    try writer.writeAll(")");
                },
                .fullpagename => {
                    try writer.writeAll("support.fullPageName(");
                    try writer.writeAll(args_name);
                    try writer.writeAll(")");
                },
                .basepagename => {
                    try writer.writeAll("support.basePageName(");
                    try writer.writeAll(args_name);
                    try writer.writeAll(")");
                },
                .subpagename => {
                    try writer.writeAll("support.subPageName(");
                    try writer.writeAll(args_name);
                    try writer.writeAll(")");
                },
                .namespace => {
                    try writer.writeAll("support.namespaceText(");
                    try writer.writeAll(args_name);
                    try writer.writeAll(")");
                },
                .namespacenumber => {
                    try writer.writeAll("support.namespaceNumber(");
                    try writer.writeAll(args_name);
                    try writer.writeAll(")");
                },
                .talkpagename => {
                    try writer.writeAll("support.talkPageName(");
                    try writer.writeAll(args_name);
                    try writer.writeAll(")");
                },
                .wikimedialanguage => try writer.writeAll("support.wikimediaLanguage()"),
                else => unreachable,
            }
            try writer.writeAll(");\n");
        },
    }
}

fn emitSwitchParserFunction(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    wrapper_indexes: *const std.StringHashMap([]const u8),
    args: []const ArgNode,
    out_name: []const u8,
    args_name: []const u8,
    indent: usize,
    temp_counter: *usize,
) anyerror!void {
    const pf_switch_key_name = try allocTempLocalName(allocator, "pf_switch_key", temp_counter);
    defer allocator.free(pf_switch_key_name);
    const pf_switch_matched_name = try allocTempLocalName(allocator, "pf_switch_matched", temp_counter);
    defer allocator.free(pf_switch_matched_name);
    try writeIndent(writer, indent);
    try writer.writeAll("{\n");
    try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, wrapper_indexes, parserArgValueNodes(args, 0), pf_switch_key_name, args_name, indent + 1, temp_counter);
    try writeIndent(writer, indent + 1);
    try writer.writeAll("var ");
    try writer.writeAll(pf_switch_matched_name);
    try writer.writeAll(" = false;\n");

    var pending_start: usize = 1;
    var saw_default = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.name != null or arg.name_is_dynamic) {
            try writeIndent(writer, indent + 1);
            try writer.writeAll("if (!");
            try writer.writeAll(pf_switch_matched_name);
            try writer.writeAll(" and (");
            var wrote_cond = false;
            var label_index = pending_start;
            while (label_index < i) : (label_index += 1) {
                if (wrote_cond) try writer.writeAll(" or ");
                const key_expr = try std.fmt.allocPrint(allocator, "{s}.items", .{pf_switch_key_name});
                defer allocator.free(key_expr);
                try emitSwitchCaseComparison(allocator, writer, templates, template_indexes, wrapper_indexes, args[label_index], key_expr, args_name, indent + 1, temp_counter);
                wrote_cond = true;
            }
            if (wrote_cond) try writer.writeAll(" or ");
            if (!switchArgIsDefault(arg)) {
                const key_expr = try std.fmt.allocPrint(allocator, "{s}.items", .{pf_switch_key_name});
                defer allocator.free(key_expr);
                try emitSwitchCaseComparison(allocator, writer, templates, template_indexes, wrapper_indexes, arg, key_expr, args_name, indent + 1, temp_counter);
            } else {
                try writer.writeAll("true");
                saw_default = true;
            }
            try writer.writeAll(")) {\n");
            try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, arg.value_nodes, out_name, args_name, indent + 2, temp_counter);
            try writeIndent(writer, indent + 2);
            try writer.writeAll(pf_switch_matched_name);
            try writer.writeAll(" = true;\n");
            try writeIndent(writer, indent + 1);
            try writer.writeAll("}\n");
            pending_start = i + 1;
        }
    }

    if (!saw_default and pending_start < args.len) {
        try writeIndent(writer, indent + 1);
        try writer.writeAll("if (!");
        try writer.writeAll(pf_switch_matched_name);
        try writer.writeAll(") {\n");
        try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, args[args.len - 1].value_nodes, out_name, args_name, indent + 2, temp_counter);
        try writeIndent(writer, indent + 1);
        try writer.writeAll("}\n");
    }
    try writeIndent(writer, indent);
    try writer.writeAll("}\n");
}

fn emitSwitchCaseComparison(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    wrapper_indexes: *const std.StringHashMap([]const u8),
    arg: ArgNode,
    key_expr: []const u8,
    args_name: []const u8,
    indent: usize,
    temp_counter: *usize,
) anyerror!void {
    if (arg.name_is_dynamic) {
        const pf_case_name_name = try allocTempLocalName(allocator, "pf_case_name", temp_counter);
        defer allocator.free(pf_case_name_name);
        try writer.writeAll("blk: {\n");
        try writeIndent(writer, indent + 1);
        try writer.writeAll("var ");
        try writer.writeAll(pf_case_name_name);
        try writer.writeAll(": runtime_std.ArrayList(u8) = .empty;\n");
        try writeIndent(writer, indent + 1);
        try writer.writeAll("defer ");
        try writer.writeAll(pf_case_name_name);
        try writer.writeAll(".deinit(allocator);\n");
        const pf_case_name_ref = try std.fmt.allocPrint(allocator, "&{s}", .{pf_case_name_name});
        defer allocator.free(pf_case_name_ref);
        try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, arg.name_nodes, pf_case_name_ref, args_name, indent + 1, temp_counter);
        try writeIndent(writer, indent + 1);
        try writer.writeAll("break :blk support.wikiTextEquals(");
        try writer.writeAll(key_expr);
        try writer.writeAll(", ");
        try writer.writeAll(pf_case_name_name);
        try writer.writeAll(".items);\n");
        try writeIndent(writer, indent);
        try writer.writeAll("}");
    } else if (arg.name) |name| {
        try writer.writeAll("support.wikiTextEquals(");
        try writer.writeAll(key_expr);
        try writer.writeAll(", ");
        try appendZigStringLiteral(writer, name);
        try writer.writeAll(")");
    } else {
        const pf_case_value_name = try allocTempLocalName(allocator, "pf_case_value", temp_counter);
        defer allocator.free(pf_case_value_name);
        try writer.writeAll("blk: {\n");
        try writeIndent(writer, indent + 1);
        try writer.writeAll("var ");
        try writer.writeAll(pf_case_value_name);
        try writer.writeAll(": runtime_std.ArrayList(u8) = .empty;\n");
        try writeIndent(writer, indent + 1);
        try writer.writeAll("defer ");
        try writer.writeAll(pf_case_value_name);
        try writer.writeAll(".deinit(allocator);\n");
        const pf_case_value_ref = try std.fmt.allocPrint(allocator, "&{s}", .{pf_case_value_name});
        defer allocator.free(pf_case_value_ref);
        try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, arg.value_nodes, pf_case_value_ref, args_name, indent + 1, temp_counter);
        try writeIndent(writer, indent + 1);
        try writer.writeAll("break :blk support.wikiTextEquals(");
        try writer.writeAll(key_expr);
        try writer.writeAll(", ");
        try writer.writeAll(pf_case_value_name);
        try writer.writeAll(".items);\n");
        try writeIndent(writer, indent);
        try writer.writeAll("}");
    }
}

fn emitNodesIntoLocalBuffer(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    wrapper_indexes: *const std.StringHashMap([]const u8),
    nodes: []const Node,
    local_name: []const u8,
    args_name: []const u8,
    indent: usize,
    temp_counter: *usize,
) anyerror!void {
    const simple_expr = try simpleNodesExprAlloc(allocator, nodes);
    defer if (simple_expr) |expr| expr.deinit(allocator);
    if (simple_expr) |expr| {
        try writeIndent(writer, indent);
        try writer.writeAll("const ");
        try writer.writeAll(local_name);
        try writer.writeAll(" = support.BorrowedText{ .items = ");
        try emitSimpleNodesExpr(writer, expr, args_name);
        try writer.writeAll(" };\n");
        return;
    }
    try writeIndent(writer, indent);
    try writer.writeAll("var ");
    try writer.writeAll(local_name);
    try writer.writeAll(": runtime_std.ArrayList(u8) = .empty;\n");
    try writeIndent(writer, indent);
    try writer.writeAll("defer ");
    try writer.writeAll(local_name);
    try writer.writeAll(".deinit(allocator);\n");
    const ref_name = try std.fmt.allocPrint(allocator, "&{s}", .{local_name});
    defer allocator.free(ref_name);
    try emitNodes(allocator, writer, templates, template_indexes, wrapper_indexes, nodes, ref_name, args_name, indent, temp_counter);
}

fn parserArgValueNodes(args: []const ArgNode, index: usize) []const Node {
    return if (index < args.len) args[index].value_nodes else &.{};
}

fn switchArgIsDefault(arg: ArgNode) bool {
    if (arg.name_is_dynamic) return false;
    const name = arg.name orelse return false;
    return std.ascii.eqlIgnoreCase(name, "#default");
}

fn collectModuleWrappers(
    allocator: std.mem.Allocator,
    wrappers: *std.ArrayList(ModuleWrapper),
    wrapper_indexes: *std.StringHashMap([]const u8),
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
    nodes: []const Node,
) !void {
    for (nodes) |node| switch (node) {
        .text => {},
        .param => |param| try collectModuleWrappers(allocator, wrappers, wrapper_indexes, modules, module_indexes, param.default_nodes),
        .template_call => |call| for (call.args) |arg| {
            if (arg.name_is_dynamic) try collectModuleWrappers(allocator, wrappers, wrapper_indexes, modules, module_indexes, arg.name_nodes);
            try collectModuleWrappers(allocator, wrappers, wrapper_indexes, modules, module_indexes, arg.value_nodes);
        },
        .invoke_call => |call| {
            const module_index = module_indexes.get(call.module_name) orelse continue;
            if (modules[module_index].emit_failed) continue;
            const fn_key = try moduleWrapperKeyAlloc(allocator, call.module_name, call.function_name);
            defer allocator.free(fn_key);
            if (wrapper_indexes.contains(fn_key)) continue;
            const fn_ident = try wrapperFnIdentAlloc(allocator, call.module_name, call.function_name, wrappers.items.len);
            try wrappers.append(allocator, .{
                .module_name = try allocator.dupe(u8, call.module_name),
                .function_name = try allocator.dupe(u8, call.function_name),
                .module_ident = modules[module_index].struct_ident,
                .fn_ident = fn_ident,
            });
            try wrapper_indexes.put(try allocator.dupe(u8, fn_key), fn_ident);
            for (call.args) |arg| {
                if (arg.name_is_dynamic) try collectModuleWrappers(allocator, wrappers, wrapper_indexes, modules, module_indexes, arg.name_nodes);
                try collectModuleWrappers(allocator, wrappers, wrapper_indexes, modules, module_indexes, arg.value_nodes);
            }
        },
        .parser_func => |func| for (func.args) |arg| {
            if (arg.name_is_dynamic) try collectModuleWrappers(allocator, wrappers, wrapper_indexes, modules, module_indexes, arg.name_nodes);
            try collectModuleWrappers(allocator, wrappers, wrapper_indexes, modules, module_indexes, arg.value_nodes);
        },
    };
}

fn buildModuleInfosAlloc(
    allocator: std.mem.Allocator,
    templates: []const TemplateInfo,
    sources: *const lua.TemplateSources,
) !std.ArrayList(ModuleInfo) {
    var module_keys = std.StringHashMapUnmanaged(void){};
    defer {
        var it = module_keys.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        module_keys.deinit(allocator);
    }

    for (templates) |template| {
        if (template.parse_error != null) continue;
        try collectModuleNames(allocator, &module_keys, template.nodes);
    }

    var modules: std.ArrayList(ModuleInfo) = .empty;
    errdefer {
        for (modules.items) |module| allocator.free(module.key);
        for (modules.items) |module| allocator.free(module.struct_ident);
        for (modules.items) |module| allocator.free(module.zig_source);
        modules.deinit(allocator);
    }

    var it = module_keys.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const struct_ident = try moduleStructIdentAlloc(allocator, key, modules.items.len);
        const module_source = sources.module_sources.get(key) orelse "";
        var module: ModuleInfo = .{
            .key = try allocator.dupe(u8, key),
            .struct_ident = struct_ident,
        };
        if (module_source.len == 0) {
            module.emit_failed = true;
        } else if (module_source.len > max_generated_module_source_bytes) {
            module.emit_failed = true;
            module.too_large = true;
        } else {
            var chunk = lua.compile(allocator, module_source) catch {
                module.emit_failed = true;
                try modules.append(allocator, module);
                continue;
            };
            defer chunk.deinit();
            module.zig_source = lua.emitZigModuleAlloc(allocator, &chunk) catch {
                module.emit_failed = true;
                try modules.append(allocator, module);
                continue;
            };
            if (module.zig_source.len > max_generated_module_zig_bytes) {
                allocator.free(module.zig_source);
                module.zig_source = "";
                module.emit_failed = true;
                module.too_large = true;
            }
        }
        try modules.append(allocator, module);
    }
    return modules;
}

fn collectModuleNames(
    allocator: std.mem.Allocator,
    names: *std.StringHashMapUnmanaged(void),
    nodes: []const Node,
) !void {
    for (nodes) |node| switch (node) {
        .text => {},
        .param => |param| try collectModuleNames(allocator, names, param.default_nodes),
        .template_call => |call| for (call.args) |arg| {
            if (arg.name_is_dynamic) try collectModuleNames(allocator, names, arg.name_nodes);
            try collectModuleNames(allocator, names, arg.value_nodes);
        },
        .invoke_call => |call| {
            const gop = try names.getOrPut(allocator, call.module_name);
            if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, call.module_name);
            for (call.args) |arg| {
                if (arg.name_is_dynamic) try collectModuleNames(allocator, names, arg.name_nodes);
                try collectModuleNames(allocator, names, arg.value_nodes);
            }
        },
        .parser_func => |func| for (func.args) |arg| {
            if (arg.name_is_dynamic) try collectModuleNames(allocator, names, arg.name_nodes);
            try collectModuleNames(allocator, names, arg.value_nodes);
        },
    };
}

fn templateHasUnsupportedInvoke(
    nodes: []const Node,
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
) bool {
    for (nodes) |node| switch (node) {
        .text => {},
        .param => |param| if (templateHasUnsupportedInvoke(param.default_nodes, modules, module_indexes)) return true,
        .template_call => |call| for (call.args) |arg| {
            if (arg.name_is_dynamic and templateHasUnsupportedInvoke(arg.name_nodes, modules, module_indexes)) return true;
            if (templateHasUnsupportedInvoke(arg.value_nodes, modules, module_indexes)) return true;
        },
        .invoke_call => |call| {
            const module_index = module_indexes.get(call.module_name) orelse return true;
            if (modules[module_index].emit_failed) return true;
            for (call.args) |arg| {
                if (arg.name_is_dynamic and templateHasUnsupportedInvoke(arg.name_nodes, modules, module_indexes)) return true;
                if (templateHasUnsupportedInvoke(arg.value_nodes, modules, module_indexes)) return true;
            }
        },
        .parser_func => |func| for (func.args) |arg| {
            if (arg.name_is_dynamic and templateHasUnsupportedInvoke(arg.name_nodes, modules, module_indexes)) return true;
            if (templateHasUnsupportedInvoke(arg.value_nodes, modules, module_indexes)) return true;
        },
    };
    return false;
}

fn templateHasOversizedInvoke(
    nodes: []const Node,
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
) bool {
    for (nodes) |node| switch (node) {
        .text => {},
        .param => |param| if (templateHasOversizedInvoke(param.default_nodes, modules, module_indexes)) return true,
        .template_call => |call| for (call.args) |arg| {
            if (arg.name_is_dynamic and templateHasOversizedInvoke(arg.name_nodes, modules, module_indexes)) return true;
            if (templateHasOversizedInvoke(arg.value_nodes, modules, module_indexes)) return true;
        },
        .invoke_call => |call| {
            const module_index = module_indexes.get(call.module_name) orelse continue;
            if (modules[module_index].too_large) return true;
            for (call.args) |arg| {
                if (arg.name_is_dynamic and templateHasOversizedInvoke(arg.name_nodes, modules, module_indexes)) return true;
                if (templateHasOversizedInvoke(arg.value_nodes, modules, module_indexes)) return true;
            }
        },
        .parser_func => |func| for (func.args) |arg| {
            if (arg.name_is_dynamic and templateHasOversizedInvoke(arg.name_nodes, modules, module_indexes)) return true;
            if (templateHasOversizedInvoke(arg.value_nodes, modules, module_indexes)) return true;
        },
    };
    return false;
}

fn templateDependsOnUnsupportedTemplate(
    nodes: []const Node,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
) bool {
    for (nodes) |node| switch (node) {
        .text => {},
        .param => |param| if (templateDependsOnUnsupportedTemplate(param.default_nodes, templates, template_indexes)) return true,
        .invoke_call => |call| for (call.args) |arg| {
            if (arg.name_is_dynamic and templateDependsOnUnsupportedTemplate(arg.name_nodes, templates, template_indexes)) return true;
            if (templateDependsOnUnsupportedTemplate(arg.value_nodes, templates, template_indexes)) return true;
        },
        .template_call => |call| {
            const callee_index = template_indexes.get(call.name) orelse return true;
            if (templates[callee_index].class == .unsupported) return true;
            for (call.args) |arg| {
                if (arg.name_is_dynamic and templateDependsOnUnsupportedTemplate(arg.name_nodes, templates, template_indexes)) return true;
                if (templateDependsOnUnsupportedTemplate(arg.value_nodes, templates, template_indexes)) return true;
            }
        },
        .parser_func => |func| for (func.args) |arg| {
            if (arg.name_is_dynamic and templateDependsOnUnsupportedTemplate(arg.name_nodes, templates, template_indexes)) return true;
            if (templateDependsOnUnsupportedTemplate(arg.value_nodes, templates, template_indexes)) return true;
        },
    };
    return false;
}

fn moduleUsedByWrappers(struct_ident: []const u8, wrappers: []const ModuleWrapper) bool {
    for (wrappers) |wrapper| {
        if (std.mem.eql(u8, wrapper.module_ident, struct_ident)) return true;
    }
    return false;
}

fn emitGeneratedModuleStruct(writer: *std.Io.Writer, module: ModuleInfo) !void {
    try writer.writeAll("const ");
    try writer.writeAll(module.struct_ident);
    try writer.writeAll(" = struct {\n");
    try writeIndentedBlock(writer, module.zig_source, 1);
    try writer.writeAll("};\n\n");
}

fn writeIndentedBlock(writer: *std.Io.Writer, text: []const u8, indent: usize) !void {
    var start: usize = 0;
    while (start < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        try writeIndent(writer, indent);
        try writer.writeAll(text[start..end]);
        try writer.writeByte('\n');
        start = @min(end + 1, text.len);
    }
}

fn unsupportedReasonAlloc(
    allocator: std.mem.Allocator,
    template: TemplateInfo,
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
) ![]u8 {
    if (template.source_too_large) return allocator.dupe(u8, "TemplateTooLarge");
    if (template.parse_error) |kind| return allocator.dupe(u8, @tagName(kind));
    if (templateHasOversizedInvoke(template.nodes, modules, module_indexes)) return allocator.dupe(u8, "ModuleTooLarge");
    if (templateHasUnsupportedInvoke(template.nodes, modules, module_indexes)) return allocator.dupe(u8, "InvokeEmissionFailed");
    return allocator.dupe(u8, "UnsupportedTemplateDependency");
}

fn resolveTemplateClass(
    templates: []TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    index: usize,
) CompileClass {
    if (templates[index].class_state == .resolved) return templates[index].class;
    if (templates[index].class_state == .resolving) return .compiled;
    templates[index].class_state = .resolving;

    var class: CompileClass = if (templates[index].parse_error != null or templates[index].source_too_large) .unsupported else .metadata_only;
    if (templates[index].parse_error == null and !templates[index].source_too_large) {
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
        .parser_func => |func| parserFunctionProducesVisibleOutput(func.kind),
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
        .parser_func => false,
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

    const raw_name = stripSubstPrefix(trimWikiWhitespace(parts.items[0]));
    if (startsWithInvoke(raw_name)) {
        return .{ .invoke_call = try parseInvokeNodeAlloc(allocator, raw_name, parts.items[1..]) };
    }
    if (try parseParserFunctionNodeAlloc(allocator, raw_name, parts.items[1..])) |node| {
        return node;
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

fn parseParserFunctionNodeAlloc(
    allocator: std.mem.Allocator,
    raw_name: []const u8,
    arg_segments: []const []const u8,
) ParseTemplateError!?Node {
    const colon = topLevelColon(raw_name);
    const head = trimWikiWhitespace(if (colon) |idx| raw_name[0..idx] else raw_name);
    const first_arg = if (colon) |idx| trimWikiWhitespace(raw_name[idx + 1 ..]) else null;
    const kind = parserFunctionKind(head) orelse return null;
    const merged_segments = if (first_arg) |value| blk: {
        var tmp = try allocator.alloc([]const u8, arg_segments.len + 1);
        tmp[0] = value;
        @memcpy(tmp[1..], arg_segments);
        break :blk tmp;
    } else arg_segments;
    defer if (first_arg != null) allocator.free(merged_segments);

    return .{ .parser_func = .{
        .kind = kind,
        .args = try parseArgNodesAlloc(allocator, merged_segments),
    } };
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
            const key_raw = trimWikiWhitespace(segment[0..equals]);
            const value_raw = segment[equals + 1 ..];
            var cursor: usize = 0;
            const value_nodes = try parseNodesAlloc(allocator, value_raw, &cursor, null);
            if (argNameNeedsDynamicEvaluation(key_raw)) {
                var name_cursor: usize = 0;
                const name_nodes = try parseNodesAlloc(allocator, key_raw, &name_cursor, null);
                try args.append(allocator, .{
                    .name = null,
                    .name_nodes = name_nodes,
                    .name_is_dynamic = true,
                    .value_nodes = value_nodes,
                });
            } else {
                const key = try allocator.dupe(u8, key_raw);
                try args.append(allocator, .{
                    .name = key,
                    .value_nodes = value_nodes,
                });
            }
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

fn parserFunctionKind(name: []const u8) ?ParserFunctionKind {
    const trimmed = trimWikiWhitespace(name);
    inline for ([_]struct { []const u8, ParserFunctionKind }{
        .{ "#if", .if_ },
        .{ "#ifeq", .ifeq },
        .{ "#switch", .switch_ },
        .{ "#tag", .tag },
        .{ "displaytitle", .displaytitle },
        .{ "lc", .lc },
        .{ "uc", .uc },
        .{ "lcfirst", .lcfirst },
        .{ "ucfirst", .ucfirst },
        .{ "formatnum", .formatnum },
        .{ "anchorencode", .anchorencode },
        .{ "padleft", .padleft },
        .{ "padright", .padright },
        .{ "currentday", .currentday },
        .{ "currentmonth", .currentmonth },
        .{ "currentmonthname", .currentmonthname },
        .{ "currentyear", .currentyear },
        .{ "pagename", .pagename },
        .{ "fullpagename", .fullpagename },
        .{ "basepagename", .basepagename },
        .{ "subpagename", .subpagename },
        .{ "namespace", .namespace },
        .{ "namespacenumber", .namespacenumber },
        .{ "talkpagename", .talkpagename },
        .{ "wikimedialanguage", .wikimedialanguage },
    }) |entry| {
        if (templateNameEqualsLoose(trimmed, entry[0])) return entry[1];
    }
    return null;
}

fn parserFunctionProducesVisibleOutput(kind: ParserFunctionKind) bool {
    return switch (kind) {
        .displaytitle => false,
        else => true,
    };
}

fn parserFunctionNeedsArgs(kind: ParserFunctionKind) bool {
    return switch (kind) {
        .pagename,
        .fullpagename,
        .basepagename,
        .subpagename,
        .namespace,
        .namespacenumber,
        .talkpagename,
        => true,
        else => false,
    };
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
        if (params != 0 and startsWithAt(input, i, "}}}")) {
            params -= 1;
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
        if (params != 0 and startsWithAt(input, i, "}}}")) {
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
        if (params != 0 and startsWithAt(input, i, "}}}")) {
            params -= 1;
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
        "<noinclude/>",  "<onlyinclude/>",
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
        if (params != 0 and startsWithAt(segment, i, "}}}")) {
            params -= 1;
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

fn topLevelColon(segment: []const u8) ?usize {
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
        if (params != 0 and startsWithAt(segment, i, "}}}")) {
            params -= 1;
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
        if (segment[i] == ':' and templates == 0 and params == 0 and links == 0) return i;
    }
    return null;
}

fn trimWikiWhitespace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

fn stripSubstPrefix(name: []const u8) []const u8 {
    var current = name;
    while (true) {
        if (startsWithAtIgnoreCase(current, 0, "subst:")) {
            current = trimWikiWhitespace(current["subst:".len..]);
            continue;
        }
        if (startsWithAtIgnoreCase(current, 0, "safesubst:")) {
            current = trimWikiWhitespace(current["safesubst:".len..]);
            continue;
        }
        break;
    }
    return current;
}

fn argNameNeedsDynamicEvaluation(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "{{") != null or
        std.mem.indexOf(u8, name, "{{{") != null or
        std.mem.indexOf(u8, name, "[[") != null or
        std.mem.indexOf(u8, name, "<") != null;
}

fn templateNameEqualsLoose(lhs: []const u8, rhs: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < lhs.len and isTemplateNameSpacer(lhs[i])) : (i += 1) {}
        while (j < rhs.len and isTemplateNameSpacer(rhs[j])) : (j += 1) {}
        if (i == lhs.len or j == rhs.len) break;
        if (std.ascii.toLower(lhs[i]) != std.ascii.toLower(rhs[j])) return false;
        i += 1;
        j += 1;
    }
    while (i < lhs.len and isTemplateNameSpacer(lhs[i])) : (i += 1) {}
    while (j < rhs.len and isTemplateNameSpacer(rhs[j])) : (j += 1) {}
    return i == lhs.len and j == rhs.len;
}

fn isTemplateNameSpacer(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '_' or byte == '-';
}

fn templateFnIdentAlloc(allocator: std.mem.Allocator, key: []const u8, index: usize) ![]u8 {
    return sanitizeIdentAlloc(allocator, "tpl_", key, index);
}

fn wrapperFnIdentAlloc(allocator: std.mem.Allocator, module_name: []const u8, function_name: []const u8, index: usize) ![]u8 {
    const joined = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ module_name, function_name });
    defer allocator.free(joined);
    return sanitizeIdentAlloc(allocator, "invoke_", joined, index);
}

fn moduleStructIdentAlloc(allocator: std.mem.Allocator, module_name: []const u8, index: usize) ![]u8 {
    return sanitizeIdentAlloc(allocator, "module_", module_name, index);
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

fn printDependencyFailures(allocator: std.mem.Allocator, report: lua.TemplateDependencyReport) !void {
    std.debug.print("template compiler audit failed\n", .{});
    std.debug.print("  unresolved templates: {d}\n", .{report.unresolved_templates.len});
    std.debug.print("  missing modules: {d}\n", .{report.missing_modules.len});
    std.debug.print("  lua compile failures: {d}\n", .{report.compiled_failed.len});
    std.debug.print("  lua zig emission mismatches: {d}\n", .{report.emitted_inconsistent.len});

    if (report.unresolved_templates.len != 0) {
        std.debug.print("first unresolved templates:\n", .{});
        for (report.unresolved_templates[0..@min(report.unresolved_templates.len, 16)]) |name| {
            std.debug.print("  {s}\n", .{name});
        }
    }
    if (report.missing_modules.len != 0) {
        std.debug.print("first missing modules:\n", .{});
        for (report.missing_modules[0..@min(report.missing_modules.len, 16)]) |name| {
            std.debug.print("  {s}\n", .{name});
        }
    }
    if (report.compiled_failed.len != 0) {
        std.debug.print("first lua compile failures:\n", .{});
        for (report.compiled_failed[0..@min(report.compiled_failed.len, 16)]) |failure| {
            std.debug.print("  {s}: {s}\n", .{ failure.name, failure.reason });
        }
    }
    if (report.emitted_inconsistent.len != 0) {
        std.debug.print("first lua zig emission mismatches:\n", .{});
        for (report.emitted_inconsistent[0..@min(report.emitted_inconsistent.len, 16)]) |failure| {
            std.debug.print("  {s}: {s}\n", .{ failure.name, failure.reason });
        }
    }
    _ = allocator;
}

fn printUnsupportedTemplates(allocator: std.mem.Allocator, unsupported: []const UnsupportedTemplate) !void {
    std.debug.print("template compiler left unsupported templates: {d}\n", .{unsupported.len});
    for (unsupported[0..@min(unsupported.len, 32)]) |entry| {
        std.debug.print("  {s}: {s}\n", .{ entry.key, entry.reason });
    }
    _ = allocator;
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
    try std.testing.expect(std.mem.indexOf(u8, generated.source, ".class = .metadata_only") != null);
    try std.testing.expectEqual(@as(usize, 2), generated.metadata_only_count);
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
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn tpl_inner_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn tpl_outer_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "try tpl_inner_0(out, allocator, &child_args_") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "findTemplateDispatchEntry") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "renderTemplateByName") != null);
    try std.testing.expectEqual(@as(usize, 2), generated.compiled_count);
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

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{"meta-only"}, &sources);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, ".class = .metadata_only") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn tpl_meta_only_0") == null);
    try std.testing.expectEqual(@as(usize, 1), generated.metadata_only_count);
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

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{"wrap"}, &sources);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const module_foo_0 = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn invoke_foo_bar_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "support.invokeGeneratedModuleFunction(out, allocator, module_foo_0.run, \"bar\", args);") != null);
    try std.testing.expectEqual(@as(usize, 1), generated.compiled_count);
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

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{"outer"}, &sources);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, ".class = .unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn tpl_outer_0") == null);
    try std.testing.expectEqual(@as(usize, 1), generated.unsupported.len);
    try std.testing.expectEqualStrings("UnsupportedTemplateDependency", generated.unsupported[0].reason);
}
