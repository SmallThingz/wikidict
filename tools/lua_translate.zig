const std = @import("std");
const lua = @import("lua");
const decoder = @import("decoder");
const compact_pattern_seed = @import("compact_pattern_seed");
const required_path = @import("required_path");

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
    if (std.mem.eql(u8, command, "dump-module")) {
        const input = flagValue(args[2..], "--input") orelse "data/wiktionary.xml";
        const name = flagValue(args[2..], "--name") orelse {
            printUsage();
            return;
        };
        required_path.ensureExistsOrExit(init.io, input, "wiktionary dump");
        const source = try lua.loadModuleSourceAlloc(allocator, input, name) orelse {
            std.debug.print("module not found: {s}\n", .{name});
            return error.ModuleNotFound;
        };
        std.debug.print("{s}", .{source});
        return;
    }
    if (std.mem.eql(u8, command, "deps")) {
        const input = flagValue(args[2..], "--input") orelse "data/wiktionary.xml";
        required_path.ensureExistsOrExit(init.io, input, "wiktionary dump");
        if (flagValue(args[2..], "--db")) |db_path| {
            required_path.ensureExistsOrExit(init.io, db_path, "dictionary binary");
            const template_names = try loadDbTemplateNamesAlloc(allocator, db_path);
            defer freeOwnedStrings(allocator, template_names);

            var report = try lua.analyzeTemplateDependenciesAlloc(allocator, input, template_names);
            defer report.deinit(allocator);
            try printTemplateDependencyReport(allocator, report);
            if (report.compiled_failed.len != 0 or report.emitted_inconsistent.len != 0) return error.LuaDependencyAuditFailed;
            return;
        }

        const structure = flagValue(args[2..], "--structure") orelse "data/wiktionary-structure.json";
        required_path.ensureExistsOrExit(init.io, structure, "structure report");
        const report = try lua.analyzeDependenciesAlloc(allocator, input, structure);
        try printDependencyReport(allocator, report);
        return;
    }
    if (std.mem.eql(u8, command, "audit")) {
        const input = flagValue(args[2..], "--input") orelse "data/wiktionary.xml";
        const db_path = flagValue(args[2..], "--db") orelse "data/wiktionary.bin";
        required_path.ensureExistsOrExit(init.io, input, "wiktionary dump");
        required_path.ensureExistsOrExit(init.io, db_path, "dictionary binary");

        const template_names = try loadDbTemplateNamesAlloc(allocator, db_path);
        defer freeOwnedStrings(allocator, template_names);

        var report = try lua.analyzeTemplateDependenciesAlloc(allocator, input, template_names);
        defer report.deinit(allocator);
        try printTemplateDependencyReport(allocator, report);
        if (report.unresolved_templates.len != 0 or report.compiled_failed.len != 0 or report.emitted_inconsistent.len != 0) {
            return error.LuaDependencyAuditFailed;
        }
        return;
    }
    if (std.mem.eql(u8, command, "audit-all-modules")) {
        const input = flagValue(args[2..], "--input") orelse "data/wiktionary.xml";
        const batch_size = (try parseUsizeFlag(args[2..], "--batch-size")) orelse 64;
        const start = (try parseUsizeFlag(args[2..], "--start")) orelse 0;
        const limit = try parseUsizeFlag(args[2..], "--limit");
        const workspace = flagValue(args[2..], "--workspace") orelse ".zig-cache/lua-module-audit";

        required_path.ensureExistsOrExit(init.io, input, "wiktionary dump");
        var report = try auditAllModulesToZigAlloc(init, allocator, .{
            .xml_path = input,
            .batch_size = batch_size,
            .start = start,
            .limit = limit,
            .workspace = workspace,
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
        \\dict-lua dump-module --input data/wiktionary.xml --name "string utilities"
        \\dict-lua deps [--input data/wiktionary.xml] [--structure data/wiktionary-structure.json]
        \\dict-lua deps --input data/wiktionary.xml --db data/wiktionary.bin
        \\dict-lua audit --input data/wiktionary.xml --db data/wiktionary.bin
        \\dict-lua audit-all-modules --input data/wiktionary.xml [--batch-size 64] [--start 0] [--limit N] [--workspace .zig-cache/lua-module-audit]
        \\
    , .{});
}

fn flagValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name)) return args[i + 1];
    }
    return null;
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
    std.debug.print("compiled ok: {d}\n", .{report.compiled_ok.len});
    std.debug.print("compiled failed: {d}\n", .{report.compiled_failed.len});
    std.debug.print("emitted consistent: {d}\n", .{report.emitted_consistent.len});
    std.debug.print("emitted inconsistent: {d}\n", .{report.emitted_inconsistent.len});
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
    batch_size: usize,
    start: usize,
    limit: ?usize,
    workspace: []const u8,
};

const GeneratedModuleArtifact = struct {
    name: []const u8,
    zig_source: []const u8,
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

    var sources = try lua.scanModuleSourcesAlloc(allocator, options.xml_path);
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
    var batch_counter: usize = 0;

    var last_progress: usize = 0;
    for (selected_modules, 0..) |name, idx| {
        if (idx - last_progress >= 100) {
            last_progress = idx;
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

        const source = sources.module_sources.get(name).?;
        if (!lua.isLikelyCodeModulePageName(name)) {
            try skipped_non_lua.append(allocator, try allocator.dupe(u8, name));
            continue;
        }
        switch (lua.classifyModuleSource(source)) {
            .lua => {},
            .non_lua, .empty => {
                try skipped_non_lua.append(allocator, try allocator.dupe(u8, name));
                continue;
            },
        }
        var chunk = lua.compile(allocator, source) catch |err| {
            try appendFailureAlloc(allocator, &lua_compiled_failed, name, @errorName(err));
            continue;
        };
        defer chunk.deinit();
        try lua_compiled_ok.append(allocator, try allocator.dupe(u8, name));

        const zig_source = lua.emitZigModuleAlloc(allocator, &chunk) catch |err| {
            try appendFailureAlloc(allocator, &zig_emitted_failed, name, @errorName(err));
            continue;
        };
        errdefer allocator.free(zig_source);

        try zig_emitted_ok.append(allocator, try allocator.dupe(u8, name));
        try generated_modules.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .zig_source = zig_source,
        });

        if (generated_modules.items.len >= @max(options.batch_size, 1)) {
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
        }
    }

    if (generated_modules.items.len != 0) {
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

    const source = try std.fmt.allocPrint(
        allocator,
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

    const batch_name = try std.fmt.allocPrint(allocator, "batch_{d}.zig", .{batch_id});
    defer allocator.free(batch_name);
    const batch_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspace, batch_name });
    defer allocator.free(batch_path);
    const batch_source = try buildAuditBatchSourceAlloc(allocator, modules, batch_id);
    defer allocator.free(batch_source);
    try writeFileAlloc(io, batch_path, batch_source);

    const lua_root_arg = try std.fmt.allocPrint(allocator, "-Mlua={s}/lua/root.zig", .{repo_root});
    defer allocator.free(lua_root_arg);
    const xml_decode_arg = try std.fmt.allocPrint(allocator, "-Mshared_xml_decode={s}/shared/xml_decode.zig", .{repo_root});
    defer allocator.free(xml_decode_arg);
    const root_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{batch_name});
    defer allocator.free(root_arg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "zig",
        "build-exe",
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

fn buildAuditBatchSourceAlloc(
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
        \\pub fn main() !void {
        \\    const allocator = host_std.heap.page_allocator;
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
