const std = @import("std");
const builtin = @import("builtin");
const lua = @import("lua");
const decoder = @import("decoder");
const required_path = @import("required_path");
const structure_report = @import("shared_structure_report");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2 or std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help")) {
        printUsage();
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "emit-zig")) {
        const input = flagValue(args[2..], "--input") orelse {
            printUsage();
            return;
        };
        const output = flagValue(args[2..], "--output");
        required_path.ensureExistsOrExit(init.io, input, "lua source");
        const source = try readFileAlloc(init.io, allocator, input);
        var chunk = try lua.compile(allocator, source);
        defer chunk.deinit();
        const zig_source = try lua.emitZigModuleAlloc(allocator, &chunk);
        if (output) |output_path| {
            try writeFileAlloc(init.io, output_path, zig_source);
        } else {
            std.debug.print("{s}", .{zig_source});
        }
        return;
    }
    if (std.mem.eql(u8, command, "emit-bytecode")) {
        const input = flagValue(args[2..], "--input") orelse {
            printUsage();
            return;
        };
        const module_name = flagValue(args[2..], "--name") orelse "module";
        const output = flagValue(args[2..], "--output");
        required_path.ensureExistsOrExit(init.io, input, "lua source");
        const source = try readFileAlloc(init.io, allocator, input);
        var chunk = try lua.compile(allocator, source);
        defer chunk.deinit();
        const body = try lua.emitBytecodeModuleAlloc(allocator, module_name, &chunk);
        defer allocator.free(body);
        const wrapped = try wrapStandaloneBytecodeModuleAlloc(allocator, body);
        if (output) |output_path| {
            try writeFileAlloc(init.io, output_path, wrapped);
        } else {
            std.debug.print("{s}", .{wrapped});
        }
        return;
    }
    if (std.mem.eql(u8, command, "dump-module")) {
        const input = flagValue(args[2..], "--input") orelse "data/wiktionary.xml";
        const structure_path = flagValue(args[2..], "--structure") orelse "data/wiktionary-structure.bin";
        const name = flagValue(args[2..], "--name") orelse {
            printUsage();
            return;
        };
        required_path.ensureExistsOrExit(init.io, input, "wiktionary dump");
        required_path.ensureExistsOrExit(init.io, structure_path, "structure report");
        var sources = try lua.loadAllStructureSourcesAlloc(allocator, input, structure_path);
        defer sources.deinit(allocator);
        const canonical = try lua.canonicalModuleNameAlloc(allocator, name);
        defer allocator.free(canonical);
        const source = sources.module_sources.get(canonical) orelse {
            std.debug.print("module not found: {s}\n", .{name});
            return error.ModuleNotFound;
        };
        std.debug.print("{s}", .{source});
        return;
    }
    if (std.mem.eql(u8, command, "referrers")) {
        const input = flagValue(args[2..], "--input") orelse "data/wiktionary.xml";
        const structure_path = flagValue(args[2..], "--structure") orelse "data/wiktionary-structure.bin";
        required_path.ensureExistsOrExit(init.io, input, "wiktionary dump");
        required_path.ensureExistsOrExit(init.io, structure_path, "structure report");
        var sources = try lua.loadAllStructureSourcesAlloc(allocator, input, structure_path);
        defer sources.deinit(allocator);
        if (flagValue(args[2..], "--module")) |name| {
            const referrers = try lua.findModuleReferrersFromSourcesAlloc(allocator, &sources, name);
            defer freeOwnedStrings(allocator, referrers);
            for (referrers) |referrer| std.debug.print("{s}\n", .{referrer});
            return;
        }
        if (flagValue(args[2..], "--template")) |name| {
            const referrers = try lua.findTemplateReferrersFromSourcesAlloc(allocator, &sources, name);
            defer freeOwnedStrings(allocator, referrers);
            for (referrers) |referrer| std.debug.print("{s}\n", .{referrer});
            return;
        }
        printUsage();
        return;
    }
    if (std.mem.eql(u8, command, "deps")) {
        const input = flagValue(args[2..], "--input") orelse "data/wiktionary.xml";
        required_path.ensureExistsOrExit(init.io, input, "wiktionary dump");
        if (flagValue(args[2..], "--db")) |db_path| {
            required_path.ensureExistsOrExit(init.io, db_path, "dictionary binary");
            const structure_path = flagValue(args[2..], "--structure") orelse "data/wiktionary-structure.bin";
            required_path.ensureExistsOrExit(init.io, structure_path, "structure report");
            const template_names = try loadDbTemplateNamesAlloc(init.io, allocator, db_path, structure_path);
            defer freeOwnedStrings(allocator, template_names);

            var sources = try lua.loadDependencySourcesFromStructureAlloc(allocator, input, structure_path);
            defer sources.deinit(allocator);
            var report = try lua.analyzeTemplateDependenciesFromSourcesAlloc(allocator, template_names, &sources);
            defer report.deinit(allocator);
            try printTemplateDependencyReport(allocator, report);
            if (report.compiled_failed.len != 0 or report.emitted_inconsistent.len != 0) return error.LuaDependencyAuditFailed;
            return;
        }

        const structure = flagValue(args[2..], "--structure") orelse "data/wiktionary-structure.bin";
        required_path.ensureExistsOrExit(init.io, structure, "structure report");
        const report = try lua.analyzeDependenciesAlloc(allocator, input, structure);
        try printDependencyReport(allocator, report);
        return;
    }
    if (std.mem.eql(u8, command, "deps-file")) {
        const input = flagValue(args[2..], "--input") orelse {
            printUsage();
            return;
        };
        required_path.ensureExistsOrExit(init.io, input, "lua source");
        const source = try readFileAlloc(init.io, allocator, input);
        const deps = try lua.extractModuleDependencies(allocator, source);
        defer freeOwnedStrings(allocator, deps);
        for (deps) |dep| std.debug.print("{s}\n", .{dep});
        return;
    }
    if (std.mem.eql(u8, command, "audit")) {
        const input = flagValue(args[2..], "--input") orelse "data/wiktionary.xml";
        const db_path = flagValue(args[2..], "--db") orelse "data/wiktionary.bin";
        const structure_path = flagValue(args[2..], "--structure") orelse "data/wiktionary-structure.bin";
        required_path.ensureExistsOrExit(init.io, input, "wiktionary dump");
        required_path.ensureExistsOrExit(init.io, db_path, "dictionary binary");
        required_path.ensureExistsOrExit(init.io, structure_path, "structure report");

        const template_names = try loadDbTemplateNamesAlloc(init.io, allocator, db_path, structure_path);
        defer freeOwnedStrings(allocator, template_names);

        var sources = try lua.loadDependencySourcesFromStructureAlloc(allocator, input, structure_path);
        defer sources.deinit(allocator);
        var report = try lua.analyzeTemplateDependenciesFromSourcesAlloc(allocator, template_names, &sources);
        defer report.deinit(allocator);
        try printTemplateDependencyReport(allocator, report);
        if (report.unresolved_templates.len != 0 or report.compiled_failed.len != 0 or report.emitted_inconsistent.len != 0) {
            return error.LuaDependencyAuditFailed;
        }
        return;
    }
    if (std.mem.eql(u8, command, "audit-all-modules")) {
        const input = flagValue(args[2..], "--input") orelse "data/wiktionary.xml";
        const structure_path = flagValue(args[2..], "--structure") orelse "data/wiktionary-structure.bin";
        const batch_size = (try parseUsizeFlag(args[2..], "--batch-size")) orelse 64;
        const batch_bytes = (try parseUsizeFlag(args[2..], "--batch-bytes")) orelse 64 * 1024 * 1024;
        const start = (try parseUsizeFlag(args[2..], "--start")) orelse 0;
        const limit = try parseUsizeFlag(args[2..], "--limit");
        const threads = (try parseUsizeFlag(args[2..], "--threads")) orelse defaultAuditThreads();
        const workspace = flagValue(args[2..], "--workspace") orelse ".zig-cache/lua-module-audit";
        const skip_zig_compile = flagPresent(args[2..], "--skip-zig-compile");

        required_path.ensureExistsOrExit(init.io, input, "wiktionary dump");
        required_path.ensureExistsOrExit(init.io, structure_path, "structure report");
        var report = try auditAllModulesToZigAlloc(init, allocator, .{
            .xml_path = input,
            .structure_path = structure_path,
            .batch_size = batch_size,
            .batch_bytes = batch_bytes,
            .start = start,
            .limit = limit,
            .threads = threads,
            .workspace = workspace,
            .skip_zig_compile = skip_zig_compile,
        });
        defer report.deinit(allocator);

        printAllModuleZigAuditReport(report);
        if (report.lua_compiled_failed.len != 0 or report.zig_emitted_failed.len != 0 or report.zig_compiled_failed.len != 0) {
            return error.LuaZigAuditFailed;
        }
        return;
    }

    printUsage();
}

fn printUsage() void {
    std.debug.print(
        \\dict-lua emit-zig --input path.lua [--output generated.zig]
        \\dict-lua emit-bytecode --input path.lua [--name module] [--output generated.zig]
        \\dict-lua dump-module --input data/wiktionary.xml --structure data/wiktionary-structure.bin --name "string utilities"
        \\dict-lua referrers --input data/wiktionary.xml --structure data/wiktionary-structure.bin --module "gender and number"
        \\dict-lua referrers --input data/wiktionary.xml --structure data/wiktionary-structure.bin --template "quote"
        \\dict-lua deps [--input data/wiktionary.xml] [--structure data/wiktionary-structure.bin]
        \\dict-lua deps --input data/wiktionary.xml --db data/wiktionary.bin
        \\dict-lua deps-file --input path.lua
        \\dict-lua audit --input data/wiktionary.xml --db data/wiktionary.bin
        \\dict-lua audit-all-modules --input data/wiktionary.xml --structure data/wiktionary-structure.bin [--batch-size 64] [--batch-bytes 67108864] [--start 0] [--limit N] [--threads N] [--workspace .zig-cache/lua-module-audit] [--skip-zig-compile]
        \\
    , .{});
}

fn wrapStandaloneBytecodeModuleAlloc(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll(
        \\const std = @import("std");
        \\const lua = @import("lua");
        \\const support = @import("template_compiler_support");
        \\
    );
    try out.writer.writeAll(body);
    return out.toOwnedSlice();
}

fn defaultAuditThreads() usize {
    if (builtin.single_threaded) return 1;
    return std.Thread.getCpuCount() catch 1;
}

fn flagValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name)) return args[i + 1];
    }
    return null;
}

fn flagPresent(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

fn parseUsizeFlag(args: []const []const u8, name: []const u8) !?usize {
    const value = flagValue(args, name) orelse return null;
    return try std.fmt.parseUnsigned(usize, value, 10);
}

fn renderValuesAlloc(allocator: std.mem.Allocator, values: []const lua.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (values, 0..) |value, idx| {
        if (idx != 0) try out.appendSlice(allocator, "\t");
        switch (value) {
            .nil => try out.appendSlice(allocator, "nil"),
            .boolean => |v| try out.appendSlice(allocator, if (v) "true" else "false"),
            .number => |v| {
                const text = try std.fmt.allocPrint(allocator, "{d}", .{v});
                defer allocator.free(text);
                try out.appendSlice(allocator, text);
            },
            .string => |v| try out.appendSlice(allocator, v),
            .table => try out.appendSlice(allocator, "table"),
            .generated_callable => try out.appendSlice(allocator, "function"),
            .function => try out.appendSlice(allocator, "function"),
            .iterator => try out.appendSlice(allocator, "iterator"),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn printDependencyReport(allocator: std.mem.Allocator, report: lua.DependencyReport) !void {
    std.debug.print("direct templates: {d}\n", .{report.direct_templates.len});
    std.debug.print("direct modules: {d}\n", .{report.direct_modules.len});
    std.debug.print("transitive modules: {d}\n", .{report.transitive_modules.len});
    std.debug.print("missing modules: {d}\n", .{report.missing_modules.len});
    std.debug.print("compiled ok: {d}\n", .{report.compiled_ok.len});
    std.debug.print("compiled failed: {d}\n", .{report.compiled_failed.len});
    std.debug.print("emitted consistent: {d}\n", .{report.emitted_consistent.len});
    std.debug.print("emitted inconsistent: {d}\n", .{report.emitted_inconsistent.len});
    if (report.missing_modules.len != 0) {
        std.debug.print("first missing modules:\n", .{});
        for (report.missing_modules[0..@min(report.missing_modules.len, 32)]) |name| {
            std.debug.print("  {s}\n", .{name});
        }
    }
    if (report.compiled_failed.len != 0) {
        std.debug.print("first failures:\n", .{});
        for (report.compiled_failed[0..@min(report.compiled_failed.len, 32)]) |failure| {
            std.debug.print("  {s}: {s}\n", .{ failure.name, failure.reason });
        }
    }
    if (report.emitted_inconsistent.len != 0) {
        std.debug.print("first emitted mismatches:\n", .{});
        for (report.emitted_inconsistent[0..@min(report.emitted_inconsistent.len, 32)]) |failure| {
            std.debug.print("  {s}: {s}\n", .{ failure.name, failure.reason });
        }
    }
    _ = allocator;
}

fn printTemplateDependencyReport(allocator: std.mem.Allocator, report: lua.TemplateDependencyReport) !void {
    std.debug.print("root templates: {d}\n", .{report.root_templates.len});
    std.debug.print("reachable templates: {d}\n", .{report.reachable_templates.len});
    std.debug.print("unresolved templates: {d}\n", .{report.unresolved_templates.len});
    std.debug.print("direct modules: {d}\n", .{report.direct_modules.len});
    std.debug.print("transitive modules: {d}\n", .{report.transitive_modules.len});
    std.debug.print("missing modules: {d}\n", .{report.missing_modules.len});
    std.debug.print("compiled ok: {d}\n", .{report.compiled_ok.len});
    std.debug.print("compiled failed: {d}\n", .{report.compiled_failed.len});
    std.debug.print("emitted consistent: {d}\n", .{report.emitted_consistent.len});
    std.debug.print("emitted inconsistent: {d}\n", .{report.emitted_inconsistent.len});
    if (report.unresolved_templates.len != 0) {
        std.debug.print("first unresolved templates:\n", .{});
        for (report.unresolved_templates[0..@min(report.unresolved_templates.len, 32)]) |name| {
            std.debug.print("  {s}\n", .{name});
        }
    }
    if (report.missing_modules.len != 0) {
        std.debug.print("first missing modules:\n", .{});
        for (report.missing_modules[0..@min(report.missing_modules.len, 32)]) |name| {
            std.debug.print("  {s}\n", .{name});
        }
    }
    if (report.compiled_failed.len != 0) {
        std.debug.print("first failures:\n", .{});
        for (report.compiled_failed[0..@min(report.compiled_failed.len, 32)]) |failure| {
            std.debug.print("  {s}: {s}\n", .{ failure.name, failure.reason });
        }
    }
    if (report.emitted_inconsistent.len != 0) {
        std.debug.print("first emitted mismatches:\n", .{});
        for (report.emitted_inconsistent[0..@min(report.emitted_inconsistent.len, 32)]) |failure| {
            std.debug.print("  {s}: {s}\n", .{ failure.name, failure.reason });
        }
    }
    _ = allocator;
}

const ModuleZigAuditOptions = struct {
    xml_path: []const u8,
    // Structure report supplies the full module page-ref table used to load
    // sources straight from the XML mmap without a second XML scan.
    structure_path: []const u8,
    batch_size: usize,
    batch_bytes: usize,
    start: usize,
    limit: ?usize,
    threads: usize,
    workspace: []const u8,
    skip_zig_compile: bool,
};

const GeneratedModuleArtifact = struct {
    name: []const u8,
    zig_source: []const u8,
};

const ModuleTranslationResult = union(enum) {
    pending,
    skipped_non_lua,
    lua_compiled_failed: []const u8,
    zig_emitted_failed: []const u8,
    zig_emitted_ok: []const u8,

    fn deinit(self: *ModuleTranslationResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .lua_compiled_failed => |reason| allocator.free(reason),
            .zig_emitted_failed => |reason| allocator.free(reason),
            .zig_emitted_ok => |zig_source| allocator.free(zig_source),
            .pending, .skipped_non_lua => {},
        }
        self.* = .pending;
    }
};

const TranslationWorkerState = struct {
    allocator: std.mem.Allocator,
    selected_modules: []const []const u8,
    sources: *const lua.ModuleSourceScan,
    results: []ModuleTranslationResult,
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    store_mutex: std.atomic.Mutex = .unlocked,
};

const ModuleZigAuditReport = struct {
    total_modules: usize,
    selected_modules: usize,
    skipped_non_lua: []const []const u8,
    lua_compiled_ok: []const []const u8,
    lua_compiled_failed: []const lua.ModuleCompileFailure,
    zig_emitted_ok: []const []const u8,
    zig_emitted_failed: []const lua.ModuleCompileFailure,
    zig_compiled_ok: []const []const u8,
    zig_compiled_failed: []const lua.ModuleCompileFailure,

    fn deinit(self: *ModuleZigAuditReport, allocator: std.mem.Allocator) void {
        freeOwnedStrings(allocator, self.skipped_non_lua);
        freeOwnedStrings(allocator, self.lua_compiled_ok);
        freeFailureSlice(allocator, self.lua_compiled_failed);
        freeOwnedStrings(allocator, self.zig_emitted_ok);
        freeFailureSlice(allocator, self.zig_emitted_failed);
        freeOwnedStrings(allocator, self.zig_compiled_ok);
        freeFailureSlice(allocator, self.zig_compiled_failed);
        self.* = undefined;
    }
};

fn auditAllModulesToZigAlloc(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: ModuleZigAuditOptions,
) !ModuleZigAuditReport {
    const repo_root = try std.process.currentPathAlloc(init.io, allocator);
    defer allocator.free(repo_root);

    var sources = try lua.loadAllModuleSourcesFromStructureAlloc(allocator, options.xml_path, options.structure_path);
    defer sources.deinit(allocator);

    const module_names = try collectSortedModuleNamesAlloc(allocator, &sources);
    defer freeOwnedStrings(allocator, module_names);

    const selected_start = @min(options.start, module_names.len);
    const selected_end = if (options.limit) |limit|
        @min(selected_start + limit, module_names.len)
    else
        module_names.len;
    const selected_modules = module_names[selected_start..selected_end];

    try resetAuditWorkspace(init.io, options.workspace);
    try std.Io.Dir.cwd().createDirPath(init.io, options.workspace);

    const thread_count = if (builtin.single_threaded or selected_modules.len <= 1)
        1
    else
        @max(@as(usize, 1), @min(options.threads, selected_modules.len));
    const translation_chunk_size = @max(@as(usize, 256), @min(selected_modules.len, @max(options.batch_size * 8, thread_count * 64)));

    var lua_compiled_ok: std.ArrayList([]const u8) = .empty;
    defer freeOwnedStringList(allocator, &lua_compiled_ok);
    var skipped_non_lua: std.ArrayList([]const u8) = .empty;
    defer freeOwnedStringList(allocator, &skipped_non_lua);
    var lua_compiled_failed: std.ArrayList(lua.ModuleCompileFailure) = .empty;
    defer freeFailureList(allocator, &lua_compiled_failed);
    var zig_emitted_ok: std.ArrayList([]const u8) = .empty;
    defer freeOwnedStringList(allocator, &zig_emitted_ok);
    var zig_emitted_failed: std.ArrayList(lua.ModuleCompileFailure) = .empty;
    defer freeFailureList(allocator, &zig_emitted_failed);
    var zig_compiled_ok: std.ArrayList([]const u8) = .empty;
    defer freeOwnedStringList(allocator, &zig_compiled_ok);
    var zig_compiled_failed: std.ArrayList(lua.ModuleCompileFailure) = .empty;
    defer freeFailureList(allocator, &zig_compiled_failed);
    var generated_modules: std.ArrayList(GeneratedModuleArtifact) = .empty;
    defer freeGeneratedModuleArtifacts(allocator, &generated_modules);
    var generated_batch_bytes: usize = 0;
    var batch_counter: usize = 0;

    var processed: usize = 0;
    while (processed < selected_modules.len) {
        const chunk_end = @min(processed + translation_chunk_size, selected_modules.len);
        const chunk_modules = selected_modules[processed..chunk_end];
        const translation_results = try translateModulesToZigAlloc(
            allocator,
            &sources,
            chunk_modules,
            thread_count,
        );

        for (chunk_modules, translation_results, processed..) |name, result, idx| {
            if (idx != 0 and idx % 100 == 0) {
                std.debug.print(
                    "lua->zig audit: translated {d}/{d} modules ({d} emitted, {d} compile failures, {d} emit failures)\n",
                    .{
                        idx,
                        selected_modules.len,
                        zig_emitted_ok.items.len,
                        lua_compiled_failed.items.len,
                        zig_emitted_failed.items.len,
                    },
                );
            }
            const zig_source = switch (result) {
                .pending => return error.InvalidAuditState,
                .skipped_non_lua => {
                    try skipped_non_lua.append(allocator, try allocator.dupe(u8, name));
                    continue;
                },
                .lua_compiled_failed => |reason| {
                    try appendFailureAlloc(allocator, &lua_compiled_failed, name, reason);
                    continue;
                },
                .zig_emitted_failed => |reason| {
                    try lua_compiled_ok.append(allocator, try allocator.dupe(u8, name));
                    try appendFailureAlloc(allocator, &zig_emitted_failed, name, reason);
                    continue;
                },
                .zig_emitted_ok => |zig_source| blk: {
                    try lua_compiled_ok.append(allocator, try allocator.dupe(u8, name));
                    break :blk zig_source;
                },
            };

            if (!options.skip_zig_compile and generated_modules.items.len != 0 and
                (generated_modules.items.len >= @max(options.batch_size, 1) or
                    generatedBatchWouldOverflow(generated_batch_bytes, zig_source.len, options.batch_bytes)))
            {
                try compileGeneratedModuleRangeAlloc(
                    init.io,
                    allocator,
                    repo_root,
                    options.workspace,
                    generated_modules.items,
                    &batch_counter,
                    &zig_compiled_ok,
                    &zig_compiled_failed,
                );
                std.debug.print(
                    "lua->zig audit: compiled {d}/{d} emitted modules ({d} compile failures)\n",
                    .{ zig_compiled_ok.items.len + zig_compiled_failed.items.len, zig_emitted_ok.items.len, zig_compiled_failed.items.len },
                );
                freeGeneratedModuleArtifacts(allocator, &generated_modules);
                generated_modules = .empty;
                generated_batch_bytes = 0;
            }

            try zig_emitted_ok.append(allocator, try allocator.dupe(u8, name));
            if (options.skip_zig_compile) {
                continue;
            }
            try generated_modules.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .zig_source = try allocator.dupe(u8, zig_source),
            });
            generated_batch_bytes += zig_source.len;
        }

        for (translation_results) |*result| result.deinit(allocator);
        allocator.free(translation_results);

        processed = chunk_end;
    }

    if (!options.skip_zig_compile and generated_modules.items.len != 0) {
        try compileGeneratedModuleRangeAlloc(
            init.io,
            allocator,
            repo_root,
            options.workspace,
            generated_modules.items,
            &batch_counter,
            &zig_compiled_ok,
            &zig_compiled_failed,
        );
        std.debug.print(
            "lua->zig audit: compiled {d}/{d} emitted modules ({d} compile failures)\n",
            .{ zig_compiled_ok.items.len + zig_compiled_failed.items.len, zig_emitted_ok.items.len, zig_compiled_failed.items.len },
        );
        freeGeneratedModuleArtifacts(allocator, &generated_modules);
        generated_modules = .empty;
        generated_batch_bytes = 0;
    }

    return .{
        .total_modules = module_names.len,
        .selected_modules = selected_modules.len,
        .skipped_non_lua = try skipped_non_lua.toOwnedSlice(allocator),
        .lua_compiled_ok = try lua_compiled_ok.toOwnedSlice(allocator),
        .lua_compiled_failed = try lua_compiled_failed.toOwnedSlice(allocator),
        .zig_emitted_ok = try zig_emitted_ok.toOwnedSlice(allocator),
        .zig_emitted_failed = try zig_emitted_failed.toOwnedSlice(allocator),
        .zig_compiled_ok = try zig_compiled_ok.toOwnedSlice(allocator),
        .zig_compiled_failed = try zig_compiled_failed.toOwnedSlice(allocator),
    };
}

fn translateModulesToZigAlloc(
    allocator: std.mem.Allocator,
    sources: *const lua.ModuleSourceScan,
    selected_modules: []const []const u8,
    thread_count: usize,
) ![]ModuleTranslationResult {
    const results = try allocator.alloc(ModuleTranslationResult, selected_modules.len);
    errdefer allocator.free(results);
    for (results) |*result| result.* = .pending;

    var state = TranslationWorkerState{
        .allocator = allocator,
        .selected_modules = selected_modules,
        .sources = sources,
        .results = results,
    };

    if (thread_count <= 1 or selected_modules.len == 0) {
        translateModulesWorker(&state);
        return results;
    }

    const worker_count = thread_count - 1;
    const workers = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(workers);

    for (workers) |*worker| {
        worker.* = try std.Thread.spawn(.{}, translateModulesWorker, .{&state});
    }
    translateModulesWorker(&state);
    for (workers) |worker| worker.join();
    return results;
}

fn translateModulesWorker(state: *TranslationWorkerState) void {
    while (true) {
        const idx = state.next_index.fetchAdd(1, .monotonic);
        if (idx >= state.selected_modules.len) break;

        const name = state.selected_modules[idx];
        const source = state.sources.module_sources.get(name).?;

        if (!lua.isLikelyCodeModulePageName(name)) {
            state.results[idx] = .skipped_non_lua;
            continue;
        }

        switch (lua.classifyNamedModuleSource(name, source)) {
            .non_lua, .empty => {
                state.results[idx] = .skipped_non_lua;
            },
            .json => {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const temp_allocator = arena.allocator();
                const zig_source = lua.emitJsonModuleAlloc(temp_allocator, source) catch |err| {
                    storeWorkerReason(state, idx, .lua_compiled_failed, @errorName(err));
                    continue;
                };
                storeWorkerOwnedSource(state, idx, zig_source);
            },
            .lua => {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const temp_allocator = arena.allocator();
                var chunk = lua.compile(temp_allocator, source) catch |err| {
                    storeWorkerReason(state, idx, .lua_compiled_failed, @errorName(err));
                    continue;
                };
                defer chunk.deinit();
                const zig_source = lua.emitZigModuleAlloc(temp_allocator, &chunk) catch |err| {
                    storeWorkerReason(state, idx, .zig_emitted_failed, @errorName(err));
                    continue;
                };
                storeWorkerOwnedSource(state, idx, zig_source);
            },
        }
    }
}

fn storeWorkerReason(
    state: *TranslationWorkerState,
    idx: usize,
    comptime tag: enum { lua_compiled_failed, zig_emitted_failed },
    reason: []const u8,
) void {
    lockAtomicMutex(&state.store_mutex);
    defer state.store_mutex.unlock();
    const owned = state.allocator.dupe(u8, reason) catch @panic("failed to duplicate worker reason");
    state.results[idx] = switch (tag) {
        .lua_compiled_failed => .{ .lua_compiled_failed = owned },
        .zig_emitted_failed => .{ .zig_emitted_failed = owned },
    };
}

fn storeWorkerOwnedSource(state: *TranslationWorkerState, idx: usize, zig_source: []const u8) void {
    lockAtomicMutex(&state.store_mutex);
    defer state.store_mutex.unlock();
    const owned = state.allocator.dupe(u8, zig_source) catch @panic("failed to duplicate generated Zig source");
    state.results[idx] = .{ .zig_emitted_ok = owned };
}

fn lockAtomicMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

fn printAllModuleZigAuditReport(report: ModuleZigAuditReport) void {
    std.debug.print("total xml modules: {d}\n", .{report.total_modules});
    std.debug.print("selected modules: {d}\n", .{report.selected_modules});
    std.debug.print("skipped non-lua: {d}\n", .{report.skipped_non_lua.len});
    std.debug.print("lua compiled ok: {d}\n", .{report.lua_compiled_ok.len});
    std.debug.print("lua compiled failed: {d}\n", .{report.lua_compiled_failed.len});
    std.debug.print("zig emitted ok: {d}\n", .{report.zig_emitted_ok.len});
    std.debug.print("zig emitted failed: {d}\n", .{report.zig_emitted_failed.len});
    std.debug.print("zig compiled ok: {d}\n", .{report.zig_compiled_ok.len});
    std.debug.print("zig compiled failed: {d}\n", .{report.zig_compiled_failed.len});
    if (report.lua_compiled_failed.len != 0) {
        std.debug.print("first lua compile failures:\n", .{});
        for (report.lua_compiled_failed[0..@min(report.lua_compiled_failed.len, 32)]) |failure| {
            std.debug.print("  {s}: {s}\n", .{ failure.name, failure.reason });
        }
    }
    if (report.skipped_non_lua.len != 0) {
        std.debug.print("first skipped non-lua module pages:\n", .{});
        for (report.skipped_non_lua[0..@min(report.skipped_non_lua.len, 32)]) |name| {
            std.debug.print("  {s}\n", .{name});
        }
    }
    if (report.zig_emitted_failed.len != 0) {
        std.debug.print("first zig emit failures:\n", .{});
        for (report.zig_emitted_failed[0..@min(report.zig_emitted_failed.len, 32)]) |failure| {
            std.debug.print("  {s}: {s}\n", .{ failure.name, failure.reason });
        }
    }
    if (report.zig_compiled_failed.len != 0) {
        std.debug.print("first zig compile failures:\n", .{});
        for (report.zig_compiled_failed[0..@min(report.zig_compiled_failed.len, 32)]) |failure| {
            std.debug.print("  {s}: {s}\n", .{ failure.name, failure.reason });
        }
    }
}

fn collectSortedModuleNamesAlloc(allocator: std.mem.Allocator, sources: *const lua.ModuleSourceScan) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, sources.module_sources.count());
    errdefer allocator.free(out);

    var it = sources.module_sources.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) {
        out[idx] = try allocator.dupe(u8, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, out, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return out;
}

fn freeFailureSlice(allocator: std.mem.Allocator, failures: []const lua.ModuleCompileFailure) void {
    for (failures) |failure| {
        allocator.free(failure.name);
        allocator.free(failure.reason);
    }
    allocator.free(failures);
}

fn freeFailureList(allocator: std.mem.Allocator, list: *std.ArrayList(lua.ModuleCompileFailure)) void {
    for (list.items) |failure| {
        allocator.free(failure.name);
        allocator.free(failure.reason);
    }
    list.deinit(allocator);
}

fn freeOwnedStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

fn freeGeneratedModuleArtifacts(allocator: std.mem.Allocator, list: *std.ArrayList(GeneratedModuleArtifact)) void {
    for (list.items) |artifact| {
        allocator.free(artifact.name);
        allocator.free(artifact.zig_source);
    }
    list.deinit(allocator);
}

fn generatedBatchWouldOverflow(current_bytes: usize, next_bytes: usize, limit_bytes: usize) bool {
    if (limit_bytes == 0) return false;
    return current_bytes > limit_bytes -| next_bytes;
}

fn appendFailureAlloc(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(lua.ModuleCompileFailure),
    name: []const u8,
    reason: []const u8,
) !void {
    try list.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .reason = try allocator.dupe(u8, reason),
    });
}

fn resetAuditWorkspace(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().deleteTree(io, path);
}

fn writeAuditBuildScriptAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace: []const u8,
    repo_root: []const u8,
) !void {
    const build_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{workspace});
    defer allocator.free(build_path);
    const lua_root_path = try std.fmt.allocPrint(allocator, "{s}/lua/root.zig", .{repo_root});
    defer allocator.free(lua_root_path);
    const xml_decode_path = try std.fmt.allocPrint(allocator, "{s}/shared/xml_decode.zig", .{repo_root});
    defer allocator.free(xml_decode_path);

    const source = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    const shared_xml_decode = b.addModule("shared_xml_decode", .{{
        \\        .root_source_file = .{{ .cwd_relative = "{s}" }},
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\    const lua_mod = b.addModule("lua", .{{
        \\        .root_source_file = .{{ .cwd_relative = "{s}" }},
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\    lua_mod.addImport("shared_xml_decode", shared_xml_decode);
        \\
        \\    const exe = b.addExecutable(.{{
        \\        .name = "lua-zig-audit",
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("root.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }}),
        \\    }});
        \\    exe.root_module.addImport("lua", lua_mod);
        \\    b.installArtifact(exe);
        \\}}
        \\
    , .{ xml_decode_path, lua_root_path });
    defer allocator.free(source);
    try writeFileAlloc(io, build_path, source);
}

fn compileGeneratedModuleRangeAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    workspace: []const u8,
    modules: []const GeneratedModuleArtifact,
    batch_counter: *usize,
    compiled_ok: *std.ArrayList([]const u8),
    compiled_failed: *std.ArrayList(lua.ModuleCompileFailure),
) !void {
    if (modules.len == 0) return;

    const stderr_text = try compileGeneratedModuleBatchAlloc(io, allocator, repo_root, workspace, modules, batch_counter);
    defer if (stderr_text) |text| allocator.free(text);
    if (stderr_text == null) {
        for (modules) |artifact| try compiled_ok.append(allocator, try allocator.dupe(u8, artifact.name));
        return;
    }

    if (modules.len == 1) {
        std.debug.print("lua->zig audit: compile failed for {s}: {s}\n", .{ modules[0].name, stderr_text.? });
        try appendFailureAlloc(allocator, compiled_failed, modules[0].name, stderr_text.?);
        return;
    }

    const mid = modules.len / 2;
    try compileGeneratedModuleRangeAlloc(io, allocator, repo_root, workspace, modules[0..mid], batch_counter, compiled_ok, compiled_failed);
    try compileGeneratedModuleRangeAlloc(io, allocator, repo_root, workspace, modules[mid..], batch_counter, compiled_ok, compiled_failed);
}

fn compileGeneratedModuleBatchAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    workspace: []const u8,
    modules: []const GeneratedModuleArtifact,
    batch_counter: *usize,
) !?[]u8 {
    const batch_id = batch_counter.*;
    batch_counter.* += 1;

    const root_name = try std.fmt.allocPrint(allocator, "generated_batch_{d}.zig", .{batch_id});
    defer allocator.free(root_name);
    const root_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspace, root_name });
    defer allocator.free(root_path);

    const batch_source = try buildAuditBatchModuleSourceAlloc(allocator, modules, batch_id);
    defer allocator.free(batch_source);
    try writeFileAlloc(io, root_path, batch_source);

    const lua_root_arg = try std.fmt.allocPrint(allocator, "-Mlua={s}/lua/root.zig", .{repo_root});
    defer allocator.free(lua_root_arg);
    const xml_decode_arg = try std.fmt.allocPrint(allocator, "-Mshared_xml_decode={s}/shared/xml_decode.zig", .{repo_root});
    defer allocator.free(xml_decode_arg);
    const root_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{root_name});
    defer allocator.free(root_arg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "zig",
        "build-obj",
        "-OReleaseFast",
        "--name",
        "lua-zig-audit",
        "--dep",
        "lua",
        "--dep",
        "shared_xml_decode",
    });
    try argv.appendSlice(allocator, &.{ root_arg, lua_root_arg, xml_decode_arg });

    const result = try std.process.run(allocator, io, .{ .argv = argv.items, .cwd = .{ .path = workspace } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .exited => |code| if (code == 0) null else try trimProcessOutputAlloc(allocator, result.stderr, result.stdout),
        else => try std.fmt.allocPrint(allocator, "zig build failed: {any}", .{result.term}),
    };
}

fn buildAuditBatchModuleSourceAlloc(
    allocator: std.mem.Allocator,
    modules: []const GeneratedModuleArtifact,
    batch_id: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll(
        \\const host_std = @import("std");
        \\const host_lua = @import("lua");
        \\
    );
    for (modules, 0..) |artifact, idx| {
        try writer.print("const mod_{d}_{d} = struct {{\n", .{ batch_id, idx });
        try writer.writeAll(artifact.zig_source);
        if (!std.mem.endsWith(u8, artifact.zig_source, "\n")) try writer.writeByte('\n');
        try writer.writeAll("};\n");
    }
    try writer.writeAll(
        \\
        \\pub fn auditAll(allocator: host_std.mem.Allocator) !void {
        \\
    );
    for (modules, 0..) |_, idx| {
        try writer.print("    var result_{d}: host_lua.GeneratedRunResult = try mod_{d}_{d}.run(allocator);\n", .{ idx, batch_id, idx });
        try writer.print("    result_{d}.deinit();\n", .{idx});
    }
    try writer.writeAll(
        \\}
        \\
    );
    return out.toOwnedSlice();
}

fn trimProcessOutputAlloc(allocator: std.mem.Allocator, stderr_bytes: []const u8, stdout_bytes: []const u8) ![]u8 {
    const stderr_trimmed = std.mem.trim(u8, stderr_bytes, "\n");
    if (stderr_trimmed.len != 0) return truncateReasonAlloc(allocator, stderr_trimmed, 4096);

    const stdout_trimmed = std.mem.trim(u8, stdout_bytes, "\n");
    if (stdout_trimmed.len != 0) return truncateReasonAlloc(allocator, stdout_trimmed, 4096);

    return allocator.dupe(u8, "zig build failed with empty stderr");
}

fn truncateReasonAlloc(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    if (text.len <= max_len) return allocator.dupe(u8, text);
    return std.fmt.allocPrint(allocator, "{s}...", .{text[0 .. max_len - 3]});
}

const MappedReadOnlyFile = struct {
    mapping: []align(std.heap.page_size_min) const u8,

    fn deinit(self: *MappedReadOnlyFile) void {
        std.posix.munmap(self.mapping);
        self.* = undefined;
    }
};

fn loadDbTemplateNamesAlloc(io: std.Io, allocator: std.mem.Allocator, db_path: []const u8, structure_path: []const u8) ![]const []const u8 {
    _ = db_path;
    var template_mappings = try structure_report.loadTemplateMappingsAlloc(io, allocator, structure_path);
    defer template_mappings.deinit(allocator);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    for (template_mappings.line_templates) |entry| try names.append(allocator, try allocator.dupe(u8, entry.name));
    for (template_mappings.translation_templates) |entry| try names.append(allocator, try allocator.dupe(u8, entry.name));
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

    const mapping = try std.posix.mmap(
        null,
        len,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    );
    return .{ .mapping = mapping };
}

fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const buffer = try allocator.alloc(u8, len);
    _ = try file.readPositionalAll(io, buffer, 0);
    return buffer;
}

fn writeFileAlloc(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}
