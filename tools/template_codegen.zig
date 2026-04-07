const std = @import("std");
const lua = @import("lua");
const required_path = @import("required_path");
pub const structure_report = @import("shared_structure_report");

const support_import = "template_compiler_support";
// Reachable Wiktionary templates/modules must compile even when they are large.
// Do not reintroduce source-size caps here; they only mask unsupported cases.
const max_generated_template_source_bytes = std.math.maxInt(usize);
const max_generated_module_source_bytes = std.math.maxInt(usize);
const max_generated_module_zig_bytes = std.math.maxInt(usize);

const CompileMode = enum {
    zig,
    bytecode,
};

pub fn main(init: std.process.Init) !void {
    const args_allocator = init.arena.allocator();
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(args_allocator);
    const options = try parseOptions(args[1..]);

    required_path.ensureExistsOrExit(init.io, options.input_path, "wiktionary dump");
    required_path.ensureExistsOrExit(init.io, options.structure_path, "structure report");

    var manual_report: ?lua.TemplateDependencyReport = null;
    defer if (manual_report) |*report| report.deinit(allocator);

    var stored_dependencies: ?structure_report.DependencySet = null;
    defer if (stored_dependencies) |*deps| deps.deinit(allocator);
    var stored_mappings: ?structure_report.TemplateMappings = null;
    defer if (stored_mappings) |*mappings| mappings.deinit(allocator);

    var roots_count: usize = 0;
    var root_templates: []const []const u8 = &.{};
    var owned_root_templates: []const []const u8 = &.{};
    defer if (owned_root_templates.len != 0) freeOwnedStrings(allocator, owned_root_templates);
    var reachable_templates: []const []const u8 = &.{};
    var owned_reachable_templates: []const []const u8 = &.{};
    defer if (owned_reachable_templates.len != 0) freeOwnedStrings(allocator, owned_reachable_templates);
    var required_modules: []const []const u8 = &.{};
    var owned_required_modules: []const []const u8 = &.{};
    defer if (owned_required_modules.len != 0) freeOwnedStrings(allocator, owned_required_modules);
    var dispatch_templates: []const structure_report.TemplateSpec = &.{};
    var owned_dispatch_templates: []structure_report.TemplateSpec = &.{};
    defer if (owned_dispatch_templates.len != 0) freeTemplateSpecs(allocator, owned_dispatch_templates);
    var dynamic_templates: []const []const u8 = &.{};
    var owned_dynamic_templates: []const []const u8 = &.{};
    defer if (owned_dynamic_templates.len != 0) freeOwnedStrings(allocator, owned_dynamic_templates);
    var audit_view: DependencyAuditView = .{};
    var maybe_sources: ?lua.TemplateSources = null;
    defer if (maybe_sources) |*sources| sources.deinit(allocator);

    if (options.template_name) |name| {
        stored_dependencies = try structure_report.loadDependencySetAlloc(init.io, allocator, options.structure_path);
        const deps = stored_dependencies.?;
        if (deps.all_template_pages.len == 0 and deps.all_module_pages.len == 0) {
            std.debug.print(
                "template compiler: structure report at {s} does not contain full source refs; rerun zig build structure\n",
                .{options.structure_path},
            );
            return error.MissingStructureDependencies;
        }
        const roots = blk: {
            const out = try allocator.alloc([]const u8, 1);
            out[0] = try allocator.dupe(u8, name);
            break :blk out;
        };
        defer freeOwnedStrings(allocator, roots);
        root_templates = roots;

        const all_template_refs = try dupLuaSourceRefsAlloc(allocator, deps.all_template_pages);
        defer freeLuaSourceRefs(allocator, all_template_refs);
        const all_module_refs = try dupLuaSourceRefsAlloc(allocator, deps.all_module_pages);
        defer freeLuaSourceRefs(allocator, all_module_refs);
        maybe_sources = try loadTemplateClosureByRefsAlloc(
            allocator,
            options.input_path,
            all_template_refs,
            all_module_refs,
            roots,
        );
        try loadSupplementalModulesAlloc(allocator, options.input_path, &maybe_sources.?);

        manual_report = try lua.analyzeTemplateDependenciesFromSourcesAlloc(allocator, roots, &maybe_sources.?);
        const report = manual_report.?;
        roots_count = report.root_templates.len;
        owned_reachable_templates = try dupStringSliceAlloc(allocator, report.reachable_templates);
        reachable_templates = owned_reachable_templates;
        owned_required_modules = try dupStringSliceAlloc(allocator, report.transitive_modules);
        required_modules = owned_required_modules;
        owned_dispatch_templates = try buildSequentialTemplateSpecsAlloc(allocator, reachable_templates);
        dispatch_templates = owned_dispatch_templates;
        owned_dynamic_templates = try collectDynamicTemplateNamesAlloc(allocator, reachable_templates, &maybe_sources.?);
        dynamic_templates = owned_dynamic_templates;
        audit_view = .{
            .unresolved_templates = report.unresolved_templates,
            .missing_modules = report.missing_modules,
            .compiled_failed = report.compiled_failed,
            .emitted_inconsistent = report.emitted_inconsistent,
        };
    } else {
        stored_dependencies = try structure_report.loadDependencySetAlloc(init.io, allocator, options.structure_path);
        stored_mappings = try structure_report.loadTemplateMappingsAlloc(init.io, allocator, options.structure_path);
        const deps = stored_dependencies.?;
        const mappings = stored_mappings.?;
        if (deps.root_templates.len != 0) {
            owned_root_templates = try dupStringSliceAlloc(allocator, deps.root_templates);
        } else {
            owned_root_templates = try loadActiveTemplateRootsAlloc(init.io, allocator, options.structure_path);
        }
        root_templates = owned_root_templates;
        if (root_templates.len == 0 and deps.transitive_modules.len == 0) {
            std.debug.print(
                "template compiler: structure report at {s} does not contain active bin template roots; rerun zig build structure\n",
                .{options.structure_path},
            );
            return error.MissingStructureDependencies;
        }
        if (deps.reachable_template_pages.len == 0 and deps.all_template_pages.len == 0 and deps.transitive_module_pages.len == 0 and deps.all_module_pages.len == 0) {
            std.debug.print(
                "template compiler: structure report at {s} does not contain dependency page refs; rerun zig build structure\n",
                .{options.structure_path},
            );
            return error.MissingStructureDependencies;
        }
        roots_count = root_templates.len;
        const selected_template_refs = try dupLuaSourceRefsAlloc(
            allocator,
            if (deps.reachable_template_pages.len != 0) deps.reachable_template_pages else deps.all_template_pages,
        );
        defer freeLuaSourceRefs(allocator, selected_template_refs);
        const selected_module_refs = try dupLuaSourceRefsAlloc(
            allocator,
            if (deps.transitive_module_pages.len != 0) deps.transitive_module_pages else deps.all_module_pages,
        );
        defer freeLuaSourceRefs(allocator, selected_module_refs);
        maybe_sources = try loadTemplateClosureByRefsAlloc(
            allocator,
            options.input_path,
            selected_template_refs,
            selected_module_refs,
            root_templates,
        );
        try loadSupplementalModulesAlloc(allocator, options.input_path, &maybe_sources.?);
        manual_report = try lua.analyzeTemplateDependenciesFromSourcesAlloc(allocator, root_templates, &maybe_sources.?);
        const report = manual_report.?;
        if (deps.reachable_templates.len != 0) {
            owned_reachable_templates = try dupStringSliceAlloc(allocator, deps.reachable_templates);
        } else {
            owned_reachable_templates = try dupStringSliceAlloc(allocator, report.reachable_templates);
        }
        reachable_templates = owned_reachable_templates;
        if (deps.transitive_modules.len != 0) {
            owned_required_modules = try dupStringSliceAlloc(allocator, deps.transitive_modules);
        } else {
            owned_required_modules = try dupStringSliceAlloc(allocator, report.transitive_modules);
        }
        required_modules = owned_required_modules;
        if (mappings.line_templates.len != reachable_templates.len) {
            std.debug.print(
                "template compiler: structure report at {s} has mismatched dispatch template table; rerun zig build structure\n",
                .{options.structure_path},
            );
            return error.InvalidStructureReport;
        }
        try validateDispatchTemplateOrder(mappings.line_templates, reachable_templates);
        dispatch_templates = mappings.line_templates;
        if (deps.dynamic_templates.len != 0) {
            owned_dynamic_templates = try dupStringSliceAlloc(allocator, deps.dynamic_templates);
        } else {
            owned_dynamic_templates = try collectDynamicTemplateNamesAlloc(allocator, reachable_templates, &maybe_sources.?);
        }
        dynamic_templates = owned_dynamic_templates;
        audit_view = .{
            .unresolved_templates = report.unresolved_templates,
            .missing_modules = report.missing_modules,
            .compiled_failed = report.compiled_failed,
            .emitted_inconsistent = report.emitted_inconsistent,
        };
    }

    const had_audit_failures = audit_view.unresolved_templates.len != 0 or
        audit_view.missing_modules.len != 0 or
        audit_view.compiled_failed.len != 0 or
        audit_view.emitted_inconsistent.len != 0;
    if (had_audit_failures) try printDependencyFailures(audit_view);

    const compiled = try compileTemplateRuntimeWithDispatchAlloc(
        allocator,
        dispatch_templates,
        dynamic_templates,
        required_modules,
        &maybe_sources.?,
        options.mode,
    );
    defer {
        allocator.free(compiled.source);
        for (compiled.unsupported) |entry| allocator.free(entry.reason);
        allocator.free(compiled.unsupported);
    }
    if (compiled.unsupported.len != 0) {
        try printUnsupportedTemplates(allocator, compiled.unsupported);
        if (options.template_name) |name| {
            const source = maybe_sources.?.template_sources.get(name) orelse "";
            if (source.len != 0) {
                std.debug.print("--- template source: {s} ---\n{s}\n", .{ name, source });
            }
        }
    }

    var file = try std.Io.Dir.cwd().createFile(init.io, options.output_path, .{ .truncate = true });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, compiled.source);

    std.debug.print(
        "template compiler: roots={d} reachable={d} dynamic={d} modules={d} compiled={d} metadata_only={d} unsupported={d} unresolved={d} missing_modules={d} output={s}\n",
        .{
            roots_count,
            reachable_templates.len,
            dynamic_templates.len,
            required_modules.len,
            compiled.compiled_count,
            compiled.metadata_only_count,
            compiled.unsupported.len,
            audit_view.unresolved_templates.len,
            audit_view.missing_modules.len,
            options.output_path,
        },
    );
}

fn loadActiveTemplateRootsAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]const []const u8 {
    var mappings = try structure_report.loadTemplateMappingsAlloc(io, allocator, path);
    defer mappings.deinit(allocator);

    var set = std.StringHashMapUnmanaged(void){};
    defer {
        var it = set.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        set.deinit(allocator);
    }

    for (mappings.line_templates) |entry| {
        const gop = try set.getOrPut(allocator, entry.name);
        if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, entry.name);
    }
    for (mappings.translation_templates) |entry| {
        const gop = try set.getOrPut(allocator, entry.name);
        if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, entry.name);
    }

    return collectStringSet(allocator, &set);
}

fn buildSequentialTemplateSpecsAlloc(
    allocator: std.mem.Allocator,
    names: []const []const u8,
) ![]structure_report.TemplateSpec {
    const out = try allocator.alloc(structure_report.TemplateSpec, names.len);
    errdefer allocator.free(out);
    for (names, out, 0..) |name, *slot, idx| {
        slot.* = .{
            .code = std.math.cast(u16, idx + 1) orelse return error.TooManyGeneratedTemplates,
            .name = try allocator.dupe(u8, name),
        };
    }
    return out;
}

fn freeTemplateSpecs(
    allocator: std.mem.Allocator,
    specs: []const structure_report.TemplateSpec,
) void {
    for (specs) |entry| allocator.free(entry.name);
    allocator.free(specs);
}

fn validateDispatchTemplateOrder(
    dispatch_templates: []const structure_report.TemplateSpec,
    reachable_templates: []const []const u8,
) !void {
    for (dispatch_templates, reachable_templates, 0..) |entry, reachable, idx| {
        const expected_code: u16 = @intCast(idx + 1);
        if (entry.code != expected_code) return error.InvalidStructureReport;
        if (!std.mem.eql(u8, entry.name, reachable)) return error.InvalidStructureReport;
    }
}

const Options = struct {
    input_path: []const u8 = "data/wiktionary.xml",
    structure_path: []const u8 = "data/wiktionary-structure.json",
    output_path: []const u8 = "data/generated_template_runtime.zig",
    template_name: ?[]const u8 = null,
    mode: CompileMode = .zig,
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
            continue;
        }
        if (std.mem.eql(u8, arg, "--structure")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.structure_path = args[i];
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
        if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.mode = std.meta.stringToEnum(CompileMode, args[i]) orelse return error.InvalidMode;
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
        \\dict-template-compile --mode zig --input data/wiktionary.xml --structure data/wiktionary-structure.json --output data/generated_template_runtime.zig
        \\dict-template-compile --mode bytecode --input data/wiktionary.xml --structure data/wiktionary-structure.json --output data/generated_template_runtime.zig
        \\dict-template-compile --mode zig --input data/wiktionary.xml --structure data/wiktionary-structure.json --template \"template name\" --output /tmp/generated_templates.zig
        \\
    , .{});
}

fn collectSourceRefNamesAlloc(
    allocator: std.mem.Allocator,
    refs: []const lua.SourcePageRef,
) ![]const []const u8 {
    var names = std.StringHashMapUnmanaged(void){};
    defer {
        var it = names.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        names.deinit(allocator);
    }

    for (refs) |ref| {
        const owned = try allocator.dupe(u8, ref.name);
        errdefer allocator.free(owned);
        const gop = try names.getOrPut(allocator, owned);
        if (gop.found_existing) {
            allocator.free(owned);
        } else {
            gop.key_ptr.* = owned;
        }
    }

    const out = try allocator.alloc([]const u8, names.count());
    var idx: usize = 0;
    var it = names.iterator();
    while (it.next()) |entry| : (idx += 1) {
        out[idx] = try allocator.dupe(u8, entry.key_ptr.*);
    }
    return out;
}

fn loadSourcesByRefsWithScanFallbackAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    template_refs: []const lua.SourcePageRef,
    module_refs: []const lua.SourcePageRef,
) !lua.TemplateSources {
    return lua.loadSelectedTemplateAndModuleSourcesByRefsAlloc(allocator, xml_path, template_refs, module_refs) catch |err| switch (err) {
        error.InvalidDictionaryFile => blk: {
            const template_names = try collectSourceRefNamesAlloc(allocator, template_refs);
            defer freeOwnedStrings(allocator, template_names);
            const module_names = try collectSourceRefNamesAlloc(allocator, module_refs);
            defer freeOwnedStrings(allocator, module_names);
            break :blk try lua.scanSelectedTemplateAndModuleSourcesAlloc(
                allocator,
                xml_path,
                template_names,
                module_names,
            );
        },
        else => err,
    };
}

fn loadSupplementalModulesAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    sources: *lua.TemplateSources,
) !void {
    const supplemental_modules = [_][]const u8{
        "libraryutil",
        "chart/default colors",
        "labels/data",
        "ml-translit",
        "pa-translit",
        "strict",
    };

    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(allocator);
    for (supplemental_modules) |name| {
        if (!sources.module_sources.contains(name)) {
            try missing.append(allocator, name);
        }
    }
    if (missing.items.len == 0) return;

    var supplemental = try lua.scanSelectedTemplateAndModuleSourcesAlloc(
        allocator,
        xml_path,
        &.{},
        missing.items,
    );
    defer supplemental.deinit(allocator);

    var it = supplemental.module_sources.iterator();
    while (it.next()) |entry| {
        if (sources.module_sources.contains(entry.key_ptr.*)) continue;
        try sources.module_sources.put(
            try allocator.dupe(u8, entry.key_ptr.*),
            try allocator.dupe(u8, entry.value_ptr.*),
        );
    }
}

pub fn loadTemplateClosureByRefsAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    all_template_refs: []const lua.SourcePageRef,
    all_module_refs: []const lua.SourcePageRef,
    root_templates: []const []const u8,
) !lua.TemplateSources {
    var sources = lua.TemplateSources{
        .template_sources = std.StringHashMap([]const u8).init(allocator),
        .module_sources = std.StringHashMap([]const u8).init(allocator),
    };
    errdefer sources.deinit(allocator);

    var wanted_templates = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &wanted_templates);
    var wanted_modules = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &wanted_modules);

    for (root_templates) |name| {
        const canonical = try lua.canonicalTemplateNameAlloc(allocator, name);
        errdefer allocator.free(canonical);
        const gop = try wanted_templates.getOrPut(allocator, canonical);
        if (gop.found_existing) {
            allocator.free(canonical);
        } else {
            gop.key_ptr.* = canonical;
        }
    }

    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        var template_batch = std.ArrayList(lua.SourcePageRef).empty;
        defer {
            if (template_batch.items.len != 0) {
                freeLuaSourceRefs(allocator, template_batch.items);
            } else {
                template_batch.deinit(allocator);
            }
        }
        var module_batch = std.ArrayList(lua.SourcePageRef).empty;
        defer {
            if (module_batch.items.len != 0) {
                freeLuaSourceRefs(allocator, module_batch.items);
            } else {
                module_batch.deinit(allocator);
            }
        }
        var missing_template_names = std.ArrayList([]const u8).empty;
        defer missing_template_names.deinit(allocator);
        var missing_module_names = std.ArrayList([]const u8).empty;
        defer missing_module_names.deinit(allocator);

        var template_it = wanted_templates.iterator();
        while (template_it.next()) |entry| {
            if (sources.template_sources.contains(entry.key_ptr.*)) continue;
            if (findStructureRefByName(all_template_refs, entry.key_ptr.*)) |ref| {
                try template_batch.append(allocator, .{
                    .name = try allocator.dupe(u8, ref.name),
                    .page_start = ref.page_start,
                    .page_end = ref.page_end,
                });
            } else {
                try missing_template_names.append(allocator, entry.key_ptr.*);
            }
        }

        var module_it = wanted_modules.iterator();
        while (module_it.next()) |entry| {
            if (sources.module_sources.contains(entry.key_ptr.*)) continue;
            if (findStructureRefByName(all_module_refs, entry.key_ptr.*)) |ref| {
                try module_batch.append(allocator, .{
                    .name = try allocator.dupe(u8, ref.name),
                    .page_start = ref.page_start,
                    .page_end = ref.page_end,
                });
            } else {
                try missing_module_names.append(allocator, entry.key_ptr.*);
            }
        }

        if (template_batch.items.len == 0 and module_batch.items.len == 0 and missing_template_names.items.len == 0 and missing_module_names.items.len == 0) break;

        if (template_batch.items.len != 0 or module_batch.items.len != 0) {
            var batch_sources = try loadSourcesByRefsWithScanFallbackAlloc(
                allocator,
                xml_path,
                template_batch.items,
                module_batch.items,
            );
            defer batch_sources.deinit(allocator);
            try mergeTemplateSourcesAlloc(allocator, &sources, &batch_sources);
        }
        if (missing_template_names.items.len != 0 or missing_module_names.items.len != 0) {
            var fallback_sources = try lua.scanSelectedTemplateAndModuleSourcesAlloc(
                allocator,
                xml_path,
                missing_template_names.items,
                missing_module_names.items,
            );
            defer fallback_sources.deinit(allocator);
            try mergeTemplateSourcesAlloc(allocator, &sources, &fallback_sources);
        }
        try loadSupplementalModulesAlloc(allocator, xml_path, &sources);
        try applyTemplateSourceOverridesAlloc(allocator, &sources);

        var report = try lua.analyzeTemplateDependenciesFromSourcesAlloc(allocator, root_templates, &sources);
        defer report.deinit(allocator);

        for (report.reachable_templates) |name| {
            if (wanted_templates.contains(name)) continue;
            try wanted_templates.put(allocator, try allocator.dupe(u8, name), {});
        }
        var loaded_template_it = sources.template_sources.iterator();
        while (loaded_template_it.next()) |entry| {
            try collectRenderedTemplateDependenciesAlloc(allocator, &wanted_templates, entry.value_ptr.*);
        }
        for (report.transitive_modules) |name| {
            if (wanted_modules.contains(name)) continue;
            try wanted_modules.put(allocator, try allocator.dupe(u8, name), {});
        }
    }

    return sources;
}

fn applyTemplateSourceOverridesAlloc(
    allocator: std.mem.Allocator,
    sources: *lua.TemplateSources,
) !void {
    try upsertTemplateSourceOverride(allocator, sources, "pagename", "{{PAGENAME}}");
    try upsertTemplateSourceOverride(allocator, sources, "yesno", "{{{1|}}}");
    try upsertTemplateSourceOverride(allocator, sources, "maintenanceline", "{{{1|}}}");
    try upsertTemplateSourceOverride(allocator, sources, "error", "{{{1|}}}");
    try upsertTemplateSourceOverride(allocator, sources, "requestbox", "{{{2|{{{1|}}}}}}");
    try upsertTemplateSourceOverride(allocator, sources, "strindex-lite", "{{#invoke:string/templates|sub|{{{1|}}}|{{{2|0}}}|{{{2|0}}}}}");
    try upsertTemplateSourceOverride(allocator, sources, "strsub-lite", "{{#invoke:string/templates|sub|{{{1|}}}|{{{2|1}}}|{{{3|}}}}}");
    try upsertTemplateSourceOverride(allocator, sources, "inflection-table-top", "");
    try upsertTemplateSourceOverride(allocator, sources, "rfd", "{{{1|}}}");
    try upsertTemplateSourceOverride(allocator, sources, "diffurl", "{{fullurl:{{{1|}}}}}");
    try upsertTemplateSourceOverride(allocator, sources, "elements/dowork", "{{{symbol|}}}");
    try upsertTemplateSourceOverride(allocator, sources, "named-after", "{{{alt|Named after {{{2|an unknown person}}}}}}");
    try upsertTemplateSourceOverride(allocator, sources, "vi-l", "{{l-lite|vi|{{{1|}}}|{{{1|}}}|{{{2|}}}|{{{3|}}}}}");
}

fn upsertTemplateSourceOverride(
    allocator: std.mem.Allocator,
    sources: *lua.TemplateSources,
    name: []const u8,
    source: []const u8,
) !void {
    const canonical = try lua.canonicalTemplateNameAlloc(allocator, name);
    const owned_source = try allocator.dupe(u8, source);
    errdefer allocator.free(owned_source);

    const gop = try sources.template_sources.getOrPut(canonical);
    if (gop.found_existing) {
        allocator.free(gop.value_ptr.*);
        allocator.free(canonical);
        gop.value_ptr.* = owned_source;
        return;
    }

    gop.key_ptr.* = canonical;
    gop.value_ptr.* = owned_source;
}

fn findStructureRefByName(
    refs: []const lua.SourcePageRef,
    name: []const u8,
) ?lua.SourcePageRef {
    for (refs) |ref| {
        if (std.mem.eql(u8, ref.name, name)) return ref;
    }
    return null;
}

fn findModuleExportId(module: ModuleInfo, function_name: []const u8) ?u16 {
    for (module.exports) |entry| {
        if (std.mem.eql(u8, entry.name, function_name)) return entry.export_id;
    }
    return null;
}

fn mergeTemplateSourcesAlloc(
    allocator: std.mem.Allocator,
    dst: *lua.TemplateSources,
    src: *const lua.TemplateSources,
) !void {
    var template_it = src.template_sources.iterator();
    while (template_it.next()) |entry| {
        if (dst.template_sources.contains(entry.key_ptr.*)) continue;
        try dst.template_sources.put(
            try allocator.dupe(u8, entry.key_ptr.*),
            try allocator.dupe(u8, entry.value_ptr.*),
        );
    }

    var module_it = src.module_sources.iterator();
    while (module_it.next()) |entry| {
        if (dst.module_sources.contains(entry.key_ptr.*)) continue;
        try dst.module_sources.put(
            try allocator.dupe(u8, entry.key_ptr.*),
            try allocator.dupe(u8, entry.value_ptr.*),
        );
    }
}

fn collectRenderedTemplateDependenciesAlloc(
    allocator: std.mem.Allocator,
    wanted_templates: *std.StringHashMapUnmanaged(void),
    source: []const u8,
) !void {
    const nodes = parseTemplateSourceAlloc(allocator, source) catch return;
    defer freeNodes(allocator, nodes);
    try collectRenderedTemplateDependenciesFromNodesAlloc(allocator, wanted_templates, nodes);
}

pub fn collectDynamicTemplateNamesAlloc(
    allocator: std.mem.Allocator,
    reachable_templates: []const []const u8,
    sources: *const lua.TemplateSources,
) ![]const []const u8 {
    var set = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &set);

    for (reachable_templates) |name| {
        const source = sources.template_sources.get(name) orelse continue;
        const nodes = parseTemplateSourceAlloc(allocator, source) catch continue;
        defer freeNodes(allocator, nodes);
        try collectDynamicTemplateNamesFromNodesAlloc(allocator, &set, nodes);
    }

    return collectStringSet(allocator, &set);
}

fn collectDynamicTemplateNamesFromNodesAlloc(
    allocator: std.mem.Allocator,
    out: *std.StringHashMapUnmanaged(void),
    nodes: []const Node,
) !void {
    for (nodes) |node| switch (node) {
        .text => {},
        .param => |param| try collectDynamicTemplateNamesFromNodesAlloc(allocator, out, param.default_nodes),
        .template_call => |call| {
            if (call.name_nodes.len != 0) {
                for (call.resolved_names) |name| {
                    if (out.contains(name)) continue;
                    try out.put(allocator, try allocator.dupe(u8, name), {});
                }
                try collectDynamicTemplateNamesFromNodesAlloc(allocator, out, call.name_nodes);
            }
            for (call.args) |arg| {
                if (arg.name_is_dynamic) try collectDynamicTemplateNamesFromNodesAlloc(allocator, out, arg.name_nodes);
                try collectDynamicTemplateNamesFromNodesAlloc(allocator, out, arg.value_nodes);
            }
        },
        .invoke_call => |call| {
            for (call.args) |arg| {
                if (arg.name_is_dynamic) try collectDynamicTemplateNamesFromNodesAlloc(allocator, out, arg.name_nodes);
                try collectDynamicTemplateNamesFromNodesAlloc(allocator, out, arg.value_nodes);
            }
        },
        .parser_func => |func| {
            for (func.args) |arg| {
                if (arg.name_is_dynamic) try collectDynamicTemplateNamesFromNodesAlloc(allocator, out, arg.name_nodes);
                try collectDynamicTemplateNamesFromNodesAlloc(allocator, out, arg.value_nodes);
            }
        },
    };
}

fn collectRenderedTemplateDependenciesFromNodesAlloc(
    allocator: std.mem.Allocator,
    wanted_templates: *std.StringHashMapUnmanaged(void),
    nodes: []const Node,
) !void {
    for (nodes) |node| switch (node) {
        .text => {},
        .param => |param| try collectRenderedTemplateDependenciesFromNodesAlloc(allocator, wanted_templates, param.default_nodes),
        .template_call => |call| {
            for (call.resolved_names) |name| {
                if (wanted_templates.contains(name)) continue;
                try wanted_templates.put(allocator, try allocator.dupe(u8, name), {});
            }
            if (call.name_nodes.len != 0) try collectRenderedTemplateDependenciesFromNodesAlloc(allocator, wanted_templates, call.name_nodes);
            for (call.args) |arg| {
                if (arg.name_is_dynamic) try collectRenderedTemplateDependenciesFromNodesAlloc(allocator, wanted_templates, arg.name_nodes);
                try collectRenderedTemplateDependenciesFromNodesAlloc(allocator, wanted_templates, arg.value_nodes);
            }
        },
        .invoke_call => |call| {
            for (call.args) |arg| {
                if (arg.name_is_dynamic) try collectRenderedTemplateDependenciesFromNodesAlloc(allocator, wanted_templates, arg.name_nodes);
                try collectRenderedTemplateDependenciesFromNodesAlloc(allocator, wanted_templates, arg.value_nodes);
            }
        },
        .parser_func => |func| {
            for (func.args) |arg| {
                if (arg.name_is_dynamic) try collectRenderedTemplateDependenciesFromNodesAlloc(allocator, wanted_templates, arg.name_nodes);
                try collectRenderedTemplateDependenciesFromNodesAlloc(allocator, wanted_templates, arg.value_nodes);
            }
        },
    };
}

const DependencyAuditView = struct {
    unresolved_templates: []const []const u8 = &.{},
    missing_modules: []const []const u8 = &.{},
    compiled_failed: []const lua.ModuleCompileFailure = &.{},
    emitted_inconsistent: []const lua.ModuleCompileFailure = &.{},
};

fn dupLuaFailureSliceAlloc(
    allocator: std.mem.Allocator,
    failures: []const structure_report.ModuleCompileFailure,
) ![]const lua.ModuleCompileFailure {
    const out = try allocator.alloc(lua.ModuleCompileFailure, failures.len);
    errdefer {
        for (out[0..failures.len]) |failure| {
            if (failure.name.len != 0) allocator.free(failure.name);
            if (failure.reason.len != 0) allocator.free(failure.reason);
        }
        allocator.free(out);
    }
    for (failures, 0..) |failure, idx| {
        out[idx] = .{
            .name = try allocator.dupe(u8, failure.name),
            .reason = try allocator.dupe(u8, failure.reason),
        };
    }
    return out;
}

fn dupLuaSourceRefsAlloc(
    allocator: std.mem.Allocator,
    refs: []const structure_report.SourcePageRef,
) ![]const lua.SourcePageRef {
    const out = try allocator.alloc(lua.SourcePageRef, refs.len);
    errdefer {
        for (out[0..refs.len]) |entry| if (entry.name.len != 0) allocator.free(entry.name);
        allocator.free(out);
    }
    for (refs, 0..) |ref, idx| {
        out[idx] = .{
            .name = try allocator.dupe(u8, ref.name),
            .page_start = ref.page_start,
            .page_end = ref.page_end,
        };
    }
    return out;
}

fn freeLuaSourceRefs(allocator: std.mem.Allocator, refs: []const lua.SourcePageRef) void {
    for (refs) |ref| allocator.free(ref.name);
    allocator.free(refs);
}

fn freeFailureSlice(
    allocator: std.mem.Allocator,
    failures: []const lua.ModuleCompileFailure,
) void {
    for (failures) |failure| {
        allocator.free(failure.name);
        allocator.free(failure.reason);
    }
    allocator.free(failures);
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
    resolved_names: []const []const u8,
    name_nodes: []const Node = &.{},
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
    ifexist,
    ifeq,
    ifexpr,
    expr,
    switch_,
    special,
    tag,
    lc,
    uc,
    lcfirst,
    ucfirst,
    formatnum,
    formatdate,
    anchorencode,
    padleft,
    padright,
    time,
    fullurl,
    urlencode,
    currentday,
    currentday2,
    currentmonth,
    currentmonthname,
    currentyear,
    revisionyear,
    revisionuser,
    pagename,
    fullpagename,
    fullpagenamee,
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

const ManualTemplateImpl = enum {
    strlen_lite,
    strindex_lite,
    strsub_lite,
    vi_l,
};

const TemplateInfo = struct {
    key: []const u8,
    dispatch_id: u16,
    source: []const u8,
    nodes: []const Node = &.{},
    parse_error: ?ParseFailureKind = null,
    source_too_large: bool = false,
    manual_impl: ?ManualTemplateImpl = null,
    class: CompileClass = .unsupported,
    class_state: enum { unresolved, resolving, resolved } = .unresolved,
    fn_ident: []const u8 = "",
};

const ParseFailureKind = enum {
    unbalanced_template,
    unsupported_template_form,
    oom,
};

const ModuleInfo = struct {
    key: []const u8,
    struct_ident: []const u8,
    // Shared generated-runtime module index used by template invokes and
    // lowered Lua require/loadData calls.
    index: u16,
    zig_source: []const u8 = "",
    exports: []const ModuleExportInfo = &.{},
    top_id: u32 = 0,
    function_count: u32 = 0,
    emit_failed: bool = false,
    too_large: bool = false,
};

const ModuleExportInfo = struct {
    export_id: u16,
    name: []const u8,
    callable_id: u32,
    fn_id: u32,
};

const UnsupportedTemplate = struct {
    key: []const u8,
    reason: []const u8,
};

fn moduleDynamicDispatchReason(zig_source: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, zig_source, "generatedTemplateDispatchFirst(") != null) return "generatedTemplateDispatchFirst";
    // A local generatedDispatchFirst helper dispatches only on compile-time
    // numeric callable ids. It does not perform string-based lookup and does
    // not allocate or materialize runtime function pointers by name, so we do
    // not treat it as a blocking dynamic-dispatch fallback here.
    if (std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleFirst(") != null) return "generatedLoadCompiledModuleFirst";
    if (std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleKnownFirst(") != null) return "generatedLoadCompiledModuleKnownFirst";
    if (std.mem.indexOf(u8, zig_source, "generatedModuleExportValueKnownFirst(") != null) return "generatedModuleExportValueKnownFirst";
    if (std.mem.indexOf(u8, zig_source, "generatedCallKnownModuleExportFirst(") != null) return "generatedCallKnownModuleExportFirst";
    if (std.mem.indexOf(u8, zig_source, "lua.generatedCall(") != null) return "lua.generatedCall";
    if (std.mem.indexOf(u8, zig_source, "lua.generatedInvoke(") != null) return "lua.generatedInvoke";
    if (std.mem.indexOf(u8, zig_source, "getGeneratedCallable(") != null) return "getGeneratedCallable";
    if (std.mem.indexOf(u8, zig_source, ".table.getGeneratedMethod(") != null) return "getGeneratedMethod";
    return null;
}

fn moduleUsesDynamicDispatch(zig_source: []const u8) bool {
    return moduleDynamicDispatchReason(zig_source) != null;
}

fn manualTemplateImplForKey(key: []const u8) ?ManualTemplateImpl {
    if (std.mem.eql(u8, key, "strlen-lite")) return .strlen_lite;
    if (std.mem.eql(u8, key, "strindex-lite")) return .strindex_lite;
    if (std.mem.eql(u8, key, "strsub-lite")) return .strsub_lite;
    if (std.mem.eql(u8, key, "vi-l")) return .vi_l;
    return null;
}

fn cloneModuleExportsAlloc(
    allocator: std.mem.Allocator,
    exports: []const lua.GeneratedModuleExportInfo,
) ![]const ModuleExportInfo {
    var out: std.ArrayList(ModuleExportInfo) = .empty;
    errdefer {
        for (out.items) |entry| allocator.free(entry.name);
        out.deinit(allocator);
    }
    for (exports) |entry| {
        try out.append(allocator, .{
            .export_id = entry.export_id,
            .name = try allocator.dupe(u8, entry.name),
            .callable_id = entry.callable_id,
            .fn_id = entry.fn_id,
        });
    }
    return out.toOwnedSlice(allocator);
}

pub const CompileRuntimeResult = struct {
    source: []u8,
    compiled_count: usize,
    metadata_only_count: usize,
    unsupported: []const UnsupportedTemplate,
};

const DynamicTemplateDispatchEntry = struct {
    normalized: []const u8,
    dispatch_id: u16,
};

fn templateCompileTraceEnabled() bool {
    return false;
}

fn normalizeTemplateLookupNameAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (name) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '_') continue;
        try out.append(allocator, std.ascii.toLower(byte));
    }
    return try out.toOwnedSlice(allocator);
}

fn buildDynamicDispatchEntriesAlloc(
    allocator: std.mem.Allocator,
    dynamic_templates: []const []const u8,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
) ![]DynamicTemplateDispatchEntry {
    var entries: std.ArrayList(DynamicTemplateDispatchEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.normalized);
        entries.deinit(allocator);
    }

    var seen = std.StringHashMapUnmanaged(void){};
    defer {
        var it = seen.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        seen.deinit(allocator);
    }

    for (dynamic_templates) |name| {
        const template_index = template_indexes.get(name) orelse continue;
        const template = templates[template_index];
        if (template.class == .unsupported) continue;

        const normalized = try normalizeTemplateLookupNameAlloc(allocator, name);
        errdefer allocator.free(normalized);
        const gop = try seen.getOrPut(allocator, normalized);
        if (gop.found_existing) {
            allocator.free(normalized);
            continue;
        }
        gop.key_ptr.* = normalized;
        try entries.append(allocator, .{
            .normalized = normalized,
            .dispatch_id = template.dispatch_id,
        });
    }

    std.mem.sort(DynamicTemplateDispatchEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: DynamicTemplateDispatchEntry, rhs: DynamicTemplateDispatchEntry) bool {
            return std.mem.order(u8, lhs.normalized, rhs.normalized) == .lt;
        }
    }.lessThan);
    return entries.toOwnedSlice(allocator);
}

pub fn compileTemplateRuntimeAlloc(
    allocator: std.mem.Allocator,
    reachable_templates: []const []const u8,
    required_modules: []const []const u8,
    sources: *const lua.TemplateSources,
) !CompileRuntimeResult {
    return compileTemplateRuntimeWithModeAlloc(
        allocator,
        reachable_templates,
        required_modules,
        sources,
        .zig,
    );
}

pub fn compileTemplateRuntimeWithModeAlloc(
    allocator: std.mem.Allocator,
    reachable_templates: []const []const u8,
    required_modules: []const []const u8,
    sources: *const lua.TemplateSources,
    mode: CompileMode,
) !CompileRuntimeResult {
    const dispatch_templates = try buildSequentialTemplateSpecsAlloc(allocator, reachable_templates);
    defer freeTemplateSpecs(allocator, dispatch_templates);
    const dynamic_templates = try collectDynamicTemplateNamesAlloc(allocator, reachable_templates, sources);
    defer freeOwnedStrings(allocator, dynamic_templates);
    return compileTemplateRuntimeWithDispatchAlloc(
        allocator,
        dispatch_templates,
        dynamic_templates,
        required_modules,
        sources,
        mode,
    );
}

fn compileTemplateRuntimeWithDispatchAlloc(
    allocator: std.mem.Allocator,
    dispatch_templates: []const structure_report.TemplateSpec,
    dynamic_templates: []const []const u8,
    required_modules: []const []const u8,
    sources: *const lua.TemplateSources,
    mode: CompileMode,
) !CompileRuntimeResult {
    var templates = try allocator.alloc(TemplateInfo, dispatch_templates.len);
    errdefer allocator.free(templates);

    var template_indexes = std.StringHashMap(usize).init(allocator);
    defer template_indexes.deinit();

    for (dispatch_templates, 0..) |entry, idx| {
        const key = entry.name;
        const duped_key = try allocator.dupe(u8, key);
        templates[idx] = .{
            .key = duped_key,
            .dispatch_id = entry.code,
            .source = sources.template_sources.get(key) orelse "",
            .manual_impl = manualTemplateImplForKey(key),
            .fn_ident = try templateFnIdentAlloc(allocator, key, idx),
        };
        try template_indexes.put(duped_key, idx);
    }

    for (templates) |*template| {
        if (template.source.len == 0) {
            continue;
        }
        if (template.manual_impl != null) {
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

    var modules = try buildModuleInfosAlloc(allocator, templates, required_modules, sources);
    defer {
        for (modules.items) |module| allocator.free(module.key);
        for (modules.items) |module| allocator.free(module.struct_ident);
        for (modules.items) |module| allocator.free(module.zig_source);
        for (modules.items) |module| {
            for (module.exports) |entry| allocator.free(entry.name);
            allocator.free(module.exports);
        }
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

    const dynamic_dispatch_entries = try buildDynamicDispatchEntriesAlloc(
        allocator,
        dynamic_templates,
        templates,
        &template_indexes,
    );
    defer {
        for (dynamic_dispatch_entries) |entry| allocator.free(entry.normalized);
        allocator.free(dynamic_dispatch_entries);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("// Generated by tools/template_codegen.zig\nconst std = @import(\"std\");\nconst lua = @import(\"lua\");\nconst support = @import(");
    try appendZigStringLiteral(writer, support_import);
    try writer.writeAll(");\n\npub const TemplateClass = support.TemplateClass;\n\n");

    for (modules.items) |module| {
        if (module.emit_failed or module.zig_source.len == 0) continue;
        try emitGeneratedModuleStruct(writer, module);
    }
    try emitGeneratedModuleCallableDispatchSupport(writer, modules.items);
    try emitGeneratedModuleDispatchSupport(writer, modules.items);
    switch (mode) {
        .zig => {
            for (templates) |template| {
                if (template.class != .compiled) continue;
                if (templateCompileTraceEnabled()) {
                    std.debug.print("template compiler trace: emit {s}\n", .{template.key});
                }
                try emitTemplateFunction(allocator, writer, templates, &template_indexes, modules.items, &module_indexes, template);
            }
        },
        .bytecode => {
            for (templates) |template| {
                if (template.class != .compiled) continue;
                if (template.manual_impl == null) continue;
                if (templateCompileTraceEnabled()) {
                    std.debug.print("template compiler trace: emit manual bytecode fallback {s}\n", .{template.key});
                }
                try emitTemplateFunction(allocator, writer, templates, &template_indexes, modules.items, &module_indexes, template);
            }
            try emitBytecodeTemplateDataAlloc(
                allocator,
                writer,
                templates,
                &template_indexes,
                modules.items,
                &module_indexes,
            );
        },
    }

    try emitClassifier(allocator, writer, templates, dynamic_dispatch_entries);
    switch (mode) {
        .zig => try emitDispatcher(writer, templates),
        .bytecode => try emitBytecodeDispatcher(writer, templates),
    }

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
            .reason = try unsupportedReasonAlloc(allocator, template, modules.items, &module_indexes, templates, &template_indexes),
        }),
    };

    return .{
        .source = try out.toOwnedSlice(),
        .compiled_count = compiled_count,
        .metadata_only_count = metadata_only_count,
        .unsupported = try unsupported.toOwnedSlice(allocator),
    };
}

fn emitClassifier(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    templates: []const TemplateInfo,
    dynamic_dispatch_entries: []const DynamicTemplateDispatchEntry,
) !void {
    try writer.writeAll(
        \\
        \\pub fn classifyTemplate(name: []const u8) ?TemplateClass {
        \\    var lo: usize = 0;
        \\    var hi: usize = template_class_entries.len;
        \\    while (lo < hi) {
        \\        const mid = lo + ((hi - lo) / 2);
        \\        const entry = template_class_entries[mid];
        \\        switch (support.compareTemplateNameToNormalized(name, entry.normalized)) {
        \\            .lt => hi = mid,
        \\            .gt => lo = mid + 1,
        \\            .eq => return entry.class,
        \\        }
        \\    }
        \\    return null;
        \\}
        \\
        \\pub const TemplateDispatchId = u16;
        \\
        \\pub fn lookupDynamicTemplateDispatchId(name: []const u8) ?TemplateDispatchId {
        \\    var lo: usize = 0;
        \\    var hi: usize = dynamic_template_dispatch_entries.len;
        \\    while (lo < hi) {
        \\        const mid = lo + ((hi - lo) / 2);
        \\        const entry = dynamic_template_dispatch_entries[mid];
        \\        switch (support.compareTemplateNameToNormalized(name, entry.normalized)) {
        \\            .lt => hi = mid,
        \\            .gt => lo = mid + 1,
        \\            .eq => return entry.dispatch_id,
        \\        }
        \\    }
        \\    return null;
        \\}
        \\
        \\const DynamicTemplateDispatchEntry = struct {
        \\    normalized: []const u8,
        \\    dispatch_id: TemplateDispatchId,
        \\};
        \\
        \\const TemplateClassEntry = struct {
        \\    normalized: []const u8,
        \\    class: TemplateClass,
        \\};
        \\
        \\const template_class_entries = [_]TemplateClassEntry{
        \\
    );
    for (templates) |template| {
        const normalized = try normalizeTemplateLookupNameAlloc(allocator, template.key);
        defer allocator.free(normalized);
        try writer.writeAll("    .{ .normalized = ");
        try appendZigStringLiteral(writer, normalized);
        try writer.writeAll(", .class = .");
        try writer.writeAll(@tagName(template.class));
        try writer.writeAll(" },\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\const dynamic_template_dispatch_entries = [_]DynamicTemplateDispatchEntry{
        \\
    );
    for (dynamic_dispatch_entries) |entry| {
        try writer.writeAll("    .{ .normalized = ");
        try appendZigStringLiteral(writer, entry.normalized);
        try writer.print(", .dispatch_id = {d} }},\n", .{entry.dispatch_id});
    }
    try writer.writeAll(
        \\};
        \\
    );
}

fn emitDispatcher(writer: *std.Io.Writer, templates: []const TemplateInfo) !void {
    try writer.writeAll(
        \\pub fn renderTemplateByDispatchId(
        \\    out: *std.ArrayList(u8),
        \\    allocator: std.mem.Allocator,
        \\    dispatch_id: TemplateDispatchId,
        \\    args: *const support.TemplateArgs,
        \\) !bool {
        \\    switch (dispatch_id) {
        \\
    );
    for (templates) |template| {
        if (template.class == .unsupported) continue;
        try writer.writeAll("        ");
        try writer.print("{d}", .{template.dispatch_id});
        try writer.writeAll(" => {\n");
        if (template.class == .compiled) {
            try writer.writeAll("            try ");
            try writer.writeAll(template.fn_ident);
            try writer.writeAll("(out, allocator, args);\n");
        }
        try writer.writeAll("            return true;\n");
        try writer.writeAll("        },\n");
    }
    try writer.writeAll(
        \\        else => return false,
        \\    }
        \\}
        \\
    );
}

fn emitBytecodeDispatcher(writer: *std.Io.Writer, templates: []const TemplateInfo) !void {
    try writer.writeAll(
        \\pub fn renderTemplateByDispatchId(
        \\    out: *std.ArrayList(u8),
        \\    allocator: std.mem.Allocator,
        \\    dispatch_id: TemplateDispatchId,
        \\    args: *const support.TemplateArgs,
        \\) !bool {
        \\    switch (dispatch_id) {
        \\
    );
    for (templates) |template| {
        if (template.class == .unsupported) continue;
        try writer.writeAll("        ");
        try writer.print("{d}", .{template.dispatch_id});
        try writer.writeAll(" => {\n");
        switch (template.class) {
            .metadata_only => {},
            .compiled => {
                if (template.manual_impl != null) {
                    try writer.writeAll("            try ");
                    try writer.writeAll(template.fn_ident);
                    try writer.writeAll("(out, allocator, args);\n");
                } else {
                    try writer.writeAll("            try support.renderBytecodeTemplate(@This(), out, allocator, ");
                    try writer.writeAll(template.fn_ident);
                    try writer.writeAll("_nodes, args);\n");
                }
            },
            .unsupported => unreachable,
        }
        try writer.writeAll("            return true;\n");
        try writer.writeAll("        },\n");
    }
    try writer.writeAll(
        \\        else => return false,
        \\    }
        \\}
        \\
    );
}

fn emitTemplateFunction(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
    template: TemplateInfo,
) anyerror!void {
    var temp_counter: usize = 0;
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
    try writer.writeAll(
        \\    _ = out;
        \\    _ = allocator;
        \\    _ = args;
        \\
    );
    if (template.manual_impl == null and !nodesUseArgs(template.nodes)) {
        try writer.writeAll("    support.touchTemplateArgs(args);\n");
    }
    if (template.manual_impl) |manual_impl| {
        switch (manual_impl) {
            .strlen_lite => try emitManualTemplateStrLenLite(writer),
            .strindex_lite => try emitManualTemplateStrIndexLite(writer),
            .strsub_lite => try emitManualTemplateStrSubLite(writer),
            .vi_l => try emitManualTemplateViL(allocator, writer, templates, template_indexes),
        }
        try writer.writeAll("}\n\n");
        return;
    }
    try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, template.nodes, "out", "args", 1, &temp_counter);
    try writer.writeAll("}\n\n");
}

const BytecodeTemplateEmitState = struct {
    allocator: std.mem.Allocator,
    next_id: usize = 0,

    fn init(allocator: std.mem.Allocator) BytecodeTemplateEmitState {
        return .{ .allocator = allocator };
    }

    fn nextName(self: *BytecodeTemplateEmitState, prefix: []const u8) ![]u8 {
        defer self.next_id += 1;
        return std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ prefix, self.next_id });
    }
};

fn emitBytecodeTemplateDataAlloc(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
) !void {
    var state = BytecodeTemplateEmitState.init(allocator);
    for (templates) |template| {
        if (template.class != .compiled) continue;
        if (template.manual_impl != null) continue;
        const nodes_name = try emitBytecodeNodesArrayAlloc(
            writer,
            &state,
            templates,
            template_indexes,
            modules,
            module_indexes,
            template.nodes,
        );
        defer allocator.free(nodes_name);
        try writer.writeAll("const ");
        try writer.writeAll(template.fn_ident);
        try writer.writeAll("_nodes = &");
        try writer.writeAll(nodes_name);
        try writer.writeAll(";\n\n");
    }
}

fn emitBytecodeNodesArrayAlloc(
    writer: *std.Io.Writer,
    state: *BytecodeTemplateEmitState,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
    nodes: []const Node,
) anyerror![]u8 {
    const name = try state.nextName("bytecode_nodes");
    errdefer state.allocator.free(name);

    var items: std.ArrayList([]u8) = .empty;
    defer {
        for (items.items) |item| state.allocator.free(item);
        items.deinit(state.allocator);
    }
    for (nodes) |node| {
        try items.append(state.allocator, try emitBytecodeNodeInitAlloc(
            state,
            templates,
            template_indexes,
            modules,
            module_indexes,
            node,
            writer,
        ));
    }

    try writer.writeAll("const ");
    try writer.writeAll(name);
    try writer.writeAll(" = [_]support.BytecodeNode{\n");
    for (items.items) |item| {
        try writer.writeAll("    ");
        try writer.writeAll(item);
        try writer.writeAll(",\n");
    }
    try writer.writeAll("};\n");
    return name;
}

fn emitBytecodeArgsArrayAlloc(
    writer: *std.Io.Writer,
    state: *BytecodeTemplateEmitState,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
    args: []const ArgNode,
) anyerror![]u8 {
    const name = try state.nextName("bytecode_args");
    errdefer state.allocator.free(name);

    var items: std.ArrayList([]u8) = .empty;
    defer {
        for (items.items) |item| state.allocator.free(item);
        items.deinit(state.allocator);
    }
    for (args) |arg| {
        try items.append(state.allocator, try emitBytecodeArgInitAlloc(
            state,
            templates,
            template_indexes,
            modules,
            module_indexes,
            arg,
            writer,
        ));
    }

    try writer.writeAll("const ");
    try writer.writeAll(name);
    try writer.writeAll(" = [_]support.BytecodeArg{\n");
    for (items.items) |item| {
        try writer.writeAll("    .{ ");
        try writer.writeAll(item);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll("};\n");
    return name;
}

fn emitBytecodeNodeInitAlloc(
    state: *BytecodeTemplateEmitState,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
    node: Node,
    writer: *std.Io.Writer,
) anyerror![]u8 {
    var out: std.Io.Writer.Allocating = .init(state.allocator);
    defer out.deinit();
    const local = &out.writer;

    switch (node) {
        .text => |text| {
            try local.writeAll(".{ .text = ");
            try appendZigStringLiteral(local, text);
            try local.writeAll(" }");
        },
        .param => |param| {
            const default_nodes = try emitBytecodeNodesArrayAlloc(writer, state, templates, template_indexes, modules, module_indexes, param.default_nodes);
            defer state.allocator.free(default_nodes);
            try local.writeAll(".{ .param = .{ .key = ");
            try appendZigStringLiteral(local, param.key);
            try local.writeAll(", .default_nodes = &");
            try local.writeAll(default_nodes);
            try local.writeAll(" } }");
        },
        .template_call => |call| {
            const args_name = try emitBytecodeArgsArrayAlloc(writer, state, templates, template_indexes, modules, module_indexes, call.args);
            defer state.allocator.free(args_name);
            const dispatch_id: u16 = blk: {
                if (call.name_nodes.len != 0) break :blk 0;
                const callee_name = if (call.resolved_names.len != 0) call.resolved_names[0] else break :blk 0;
                const callee_index = template_indexes.get(callee_name) orelse break :blk 0;
                break :blk templates[callee_index].dispatch_id;
            };
            try local.writeAll(".{ .template_call = .{ .dispatch_id = ");
            try local.print("{d}", .{dispatch_id});
            if (call.name_nodes.len != 0) {
                const name_nodes = try emitBytecodeNodesArrayAlloc(writer, state, templates, template_indexes, modules, module_indexes, call.name_nodes);
                defer state.allocator.free(name_nodes);
                try local.writeAll(", .name_nodes = &");
                try local.writeAll(name_nodes);
            }
            try local.writeAll(", .args = &");
            try local.writeAll(args_name);
            try local.writeAll(" } }");
        },
        .invoke_call => |call| {
            const args_name = try emitBytecodeArgsArrayAlloc(writer, state, templates, template_indexes, modules, module_indexes, call.args);
            defer state.allocator.free(args_name);
            const module_index = module_indexes.get(call.module_name) orelse return error.InvalidStructureReport;
            const export_id = findModuleExportId(modules[module_index], call.function_name) orelse return error.InvalidStructureReport;
            try local.writeAll(".{ .invoke_call = .{ .module_index = ");
            try local.print("{d}", .{modules[module_index].index});
            try local.writeAll(", .export_id = ");
            try local.print("{d}", .{export_id});
            try local.writeAll(", .args = &");
            try local.writeAll(args_name);
            try local.writeAll(" } }");
        },
        .parser_func => |func| {
            const args_name = try emitBytecodeArgsArrayAlloc(writer, state, templates, template_indexes, modules, module_indexes, func.args);
            defer state.allocator.free(args_name);
            try local.writeAll(".{ .parser_func = .{ .kind = .");
            try local.writeAll(@tagName(func.kind));
            try local.writeAll(", .args = &");
            try local.writeAll(args_name);
            try local.writeAll(" } }");
        },
    }
    return out.toOwnedSlice();
}

fn emitBytecodeArgInitAlloc(
    state: *BytecodeTemplateEmitState,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
    arg: ArgNode,
    writer: *std.Io.Writer,
) anyerror![]u8 {
    var out: std.Io.Writer.Allocating = .init(state.allocator);
    defer out.deinit();
    const local = &out.writer;

    if (arg.name) |static_name| {
        try local.writeAll(".name = ");
        try appendZigStringLiteral(local, static_name);
        try local.writeAll(", ");
    }
    if (arg.name_is_dynamic) {
        const name_nodes = try emitBytecodeNodesArrayAlloc(writer, state, templates, template_indexes, modules, module_indexes, arg.name_nodes);
        defer state.allocator.free(name_nodes);
        try local.writeAll(".name_is_dynamic = true, .name_nodes = &");
        try local.writeAll(name_nodes);
        try local.writeAll(", ");
    }
    const value_nodes = try emitBytecodeNodesArrayAlloc(writer, state, templates, template_indexes, modules, module_indexes, arg.value_nodes);
    defer state.allocator.free(value_nodes);
    try local.writeAll(".value_nodes = &");
    try local.writeAll(value_nodes);
    return out.toOwnedSlice();
}

// These templates are tiny string helpers or fixed wrappers whose wikitext
// form is intentionally too dynamic for the generic parser. Emitting them by
// hand keeps the generated runtime fully static while avoiding a pile of
// template-specific parse hacks in the main compiler.
fn emitManualTemplateStrLenLite(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\    const text = args.paramValue("1") orelse "";
        \\    var num_buf: [32]u8 = undefined;
        \\    const rendered = try std.fmt.bufPrint(&num_buf, "{d}", .{text.len});
        \\    try support.appendText(out, allocator, rendered);
    );
}

fn emitManualTemplateStrIndexLite(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\    const text = args.paramValue("1") orelse "";
        \\    const raw_index = std.mem.trim(u8, args.paramValue("2") orelse "0", " \t\r\n");
        \\    const one_based = std.fmt.parseUnsigned(usize, raw_index, 10) catch 0;
        \\    if (one_based >= 1 and one_based <= text.len) {
        \\        try support.appendText(out, allocator, text[one_based - 1 .. one_based]);
        \\    }
    );
}

fn emitManualTemplateStrSubLite(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\    const text = args.paramValue("1") orelse "";
        \\    const raw_start = std.mem.trim(u8, args.paramValue("2") orelse "1", " \t\r\n");
        \\    const raw_end = std.mem.trim(u8, args.paramValue("3") orelse "", " \t\r\n");
        \\    const start_one_based = std.fmt.parseUnsigned(usize, raw_start, 10) catch 1;
        \\    var start_idx: usize = if (start_one_based > 0) start_one_based - 1 else 0;
        \\    if (start_idx > text.len) start_idx = text.len;
        \\    var end_exclusive: usize = if (raw_end.len != 0)
        \\        std.fmt.parseUnsigned(usize, raw_end, 10) catch text.len
        \\    else
        \\        text.len;
        \\    if (end_exclusive > text.len) end_exclusive = text.len;
        \\    if (end_exclusive > start_idx) {
        \\        try support.appendText(out, allocator, text[start_idx..end_exclusive]);
        \\    }
    );
}

fn emitManualTemplateViL(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
) !void {
    _ = allocator;
    const hani_index = template_indexes.get("l/vi/hani") orelse return;
    const latn_index = template_indexes.get("l/vi/latn") orelse return;
    const hani_ident = templates[hani_index].fn_ident;
    const latn_ident = templates[latn_index].fn_ident;
    try writer.writeAll(
        \\    const term = args.paramValue("1") orelse "";
        \\    if (std.mem.trim(u8, term, " \t\r\n").len == 0) return;
        \\    const first = term[0];
        \\    const use_hani = std.ascii.toUpper(first) == std.ascii.toLower(first);
        \\    var child_builder: support.TemplateArgsBuilder = .{};
        \\    defer child_builder.deinit(allocator);
        \\    try child_builder.addPositionalBorrowed(allocator, term);
        \\    if (args.paramValue("2")) |tr| {
        \\        if (std.mem.trim(u8, tr, " \t\r\n").len != 0) try child_builder.addNamedBorrowed(allocator, "tr", tr);
        \\    }
        \\    if (args.paramValue("3")) |gloss| {
        \\        if (std.mem.trim(u8, gloss, " \t\r\n").len != 0) try child_builder.addNamedBorrowed(allocator, "gloss", gloss);
        \\    }
        \\    const child_args = child_builder.buildBorrowed(args.page_title);
        \\    if (use_hani) {
    );
    try writer.writeAll("        try ");
    try writer.writeAll(hani_ident);
    try writer.writeAll(
        \\(out, allocator, &child_args);
        \\    } else {
    );
    try writer.writeAll("        try ");
    try writer.writeAll(latn_ident);
    try writer.writeAll(
        \\(out, allocator, &child_args);
        \\    }
    );
}

fn emitNodes(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
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
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, param.default_nodes, out_name, args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .template_call => |call| {
            if (call.name_nodes.len == 0) {
                const callee_name = if (call.resolved_names.len != 0) call.resolved_names[0] else continue;
                const callee_index = template_indexes.get(callee_name) orelse continue;
                if (templates[callee_index].class == .metadata_only) continue;
                if (templates[callee_index].class != .compiled) continue;
                try emitNestedCall(allocator, writer, templates[callee_index].fn_ident, templates, template_indexes, modules, module_indexes, call.args, out_name, args_name, indent, temp_counter);
            } else {
                try emitDynamicNestedCall(allocator, writer, call, templates, template_indexes, modules, module_indexes, out_name, args_name, indent, temp_counter);
            }
        },
        .invoke_call => |call| {
            const module_index = module_indexes.get(call.module_name) orelse continue;
            if (modules[module_index].emit_failed) continue;
            const export_id = findModuleExportId(modules[module_index], call.function_name) orelse continue;
            try emitNestedModuleInvokeCall(allocator, writer, modules[module_index].index, export_id, templates, template_indexes, modules, module_indexes, call.args, out_name, args_name, indent, temp_counter);
        },
        .parser_func => |func| try emitParserFunction(allocator, writer, templates, template_indexes, modules, module_indexes, func, out_name, args_name, indent, temp_counter),
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
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
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
            try writer.print("var value_buf_{d}_{d}: std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent + 1);
            try writer.print("defer value_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const value_buf_name = try std.fmt.allocPrint(allocator, "&value_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(value_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.value_nodes, value_buf_name, parent_args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.print("var name_buf_{d}_{d}: std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent + 1);
            try writer.print("defer name_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const name_buf_name = try std.fmt.allocPrint(allocator, "&name_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(name_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.name_nodes, name_buf_name, parent_args_name, indent + 1, temp_counter);
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
            try writer.print("var value_buf_{d}_{d}: std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent + 1);
            try writer.print("defer value_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const value_buf_name = try std.fmt.allocPrint(allocator, "&value_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(value_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.value_nodes, value_buf_name, parent_args_name, indent + 1, temp_counter);
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
            try writer.print("var value_buf_{d}_{d}: std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent + 1);
            try writer.print("defer value_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const value_buf_name = try std.fmt.allocPrint(allocator, "&value_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(value_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.value_nodes, value_buf_name, parent_args_name, indent + 1, temp_counter);
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

fn emitDynamicNestedCall(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    call: TemplateCallNode,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
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
    try writer.print("var name_buf_{d}: std.ArrayList(u8) = .empty;\n", .{call_id});
    try writeIndent(writer, indent + 1);
    try writer.print("defer name_buf_{d}.deinit(allocator);\n", .{call_id});
    const name_buf_ref = try std.fmt.allocPrint(allocator, "&name_buf_{d}", .{call_id});
    defer allocator.free(name_buf_ref);
    try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, call.name_nodes, name_buf_ref, parent_args_name, indent + 1, temp_counter);
    try writeIndent(writer, indent + 1);
    try writer.print("if (lookupDynamicTemplateDispatchId(name_buf_{d}.items)) |dynamic_dispatch_{d}| {{\n", .{ call_id, call_id });
    try writeIndent(writer, indent + 2);
    try writer.writeAll("{\n");
    try emitNestedDispatchCall(allocator, writer, templates, template_indexes, modules, module_indexes, call.args, out_name, parent_args_name, indent + 3, temp_counter, call_id);
    try writeIndent(writer, indent + 2);
    try writer.writeAll("}\n");
    try writeIndent(writer, indent + 1);
    try writer.writeAll("}\n");

    try writeIndent(writer, indent);
    try writer.writeAll("}\n");
}

fn emitNestedDispatchCall(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
    args: []const ArgNode,
    out_name: []const u8,
    parent_args_name: []const u8,
    indent: usize,
    temp_counter: *usize,
    call_id: usize,
) anyerror!void {
    try writeIndent(writer, indent);
    try writer.print("var child_builder_{d}: support.TemplateArgsBuilder = .{{}};\n", .{call_id});
    try writeIndent(writer, indent);
    try writer.print("defer child_builder_{d}.deinit(allocator);\n", .{call_id});
    for (args, 0..) |arg, arg_index| {
        const simple_value = try simpleNodesExprAlloc(allocator, arg.value_nodes);
        defer if (simple_value) |value| value.deinit(allocator);
        try writeIndent(writer, indent);
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
            try writer.print("var value_buf_{d}_{d}: std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent);
            try writer.print("defer value_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const value_buf_name = try std.fmt.allocPrint(allocator, "&value_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(value_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.value_nodes, value_buf_name, parent_args_name, indent, temp_counter);
            try writeIndent(writer, indent);
            try writer.print("var name_buf_{d}_{d}: std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent);
            try writer.print("defer name_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const name_buf_name = try std.fmt.allocPrint(allocator, "&name_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(name_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.name_nodes, name_buf_name, parent_args_name, indent, temp_counter);
            try writeIndent(writer, indent);
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
            try writer.print("var value_buf_{d}_{d}: std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent);
            try writer.print("defer value_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const value_buf_name = try std.fmt.allocPrint(allocator, "&value_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(value_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.value_nodes, value_buf_name, parent_args_name, indent, temp_counter);
            try writeIndent(writer, indent);
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
            try writer.print("var value_buf_{d}_{d}: std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent);
            try writer.print("defer value_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const value_buf_name = try std.fmt.allocPrint(allocator, "&value_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(value_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.value_nodes, value_buf_name, parent_args_name, indent, temp_counter);
            try writeIndent(writer, indent);
            try writer.print("try child_builder_{d}.addPositionalBuffer(allocator, try value_buf_{d}_{d}.toOwnedSlice(allocator));\n", .{ call_id, call_id, arg_index });
        }
    }
    try writeIndent(writer, indent);
    try writer.print("const child_args_{d} = child_builder_{d}.buildBorrowed(", .{ call_id, call_id });
    try writer.writeAll(parent_args_name);
    try writer.writeAll(".page_title);\n");
    try writeIndent(writer, indent);
    try writer.print("_ = try renderTemplateByDispatchId({s}, allocator, dynamic_dispatch_{d}, &child_args_{d});\n", .{ out_name, call_id, call_id });
}

fn emitNestedModuleInvokeCall(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    module_index: u16,
    export_id: u16,
    templates: []const TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
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
            try writer.print("var value_buf_{d}_{d}: std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent + 1);
            try writer.print("defer value_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const value_buf_name = try std.fmt.allocPrint(allocator, "&value_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(value_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.value_nodes, value_buf_name, parent_args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.print("var name_buf_{d}_{d}: std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent + 1);
            try writer.print("defer name_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const name_buf_name = try std.fmt.allocPrint(allocator, "&name_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(name_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.name_nodes, name_buf_name, parent_args_name, indent + 1, temp_counter);
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
            try writer.print("var value_buf_{d}_{d}: std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent + 1);
            try writer.print("defer value_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const value_buf_name = try std.fmt.allocPrint(allocator, "&value_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(value_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.value_nodes, value_buf_name, parent_args_name, indent + 1, temp_counter);
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
            try writer.print("var value_buf_{d}_{d}: std.ArrayList(u8) = .empty;\n", .{ call_id, arg_index });
            try writeIndent(writer, indent + 1);
            try writer.print("defer value_buf_{d}_{d}.deinit(allocator);\n", .{ call_id, arg_index });
            const value_buf_name = try std.fmt.allocPrint(allocator, "&value_buf_{d}_{d}", .{ call_id, arg_index });
            defer allocator.free(value_buf_name);
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.value_nodes, value_buf_name, parent_args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.print("try child_builder_{d}.addPositionalBuffer(allocator, try value_buf_{d}_{d}.toOwnedSlice(allocator));\n", .{ call_id, call_id, arg_index });
        }
    }
    try writeIndent(writer, indent + 1);
    try writer.print("const child_args_{d} = child_builder_{d}.buildBorrowed(", .{ call_id, call_id });
    try writer.writeAll(parent_args_name);
    try writer.writeAll(".page_title);\n");
    try writeIndent(writer, indent + 1);
    try writer.writeAll("try generatedRenderModuleByIndex(");
    try writer.writeAll(out_name);
    try writer.writeAll(", allocator, ");
    try writer.print("{d}, ", .{module_index});
    try writer.print("{d}", .{export_id});
    try writer.print(", &child_args_{d});\n", .{call_id});
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
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
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
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 0), pf_cond_name, args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("if (support.isTruthy(");
            try writer.writeAll(pf_cond_name);
            try writer.writeAll(".items)) {\n");
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 1), out_name, args_name, indent + 2, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("} else {\n");
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 2), out_name, args_name, indent + 2, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("}\n");
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .ifexist => {
            const pf_title_name = try allocTempLocalName(allocator, "pf_title", temp_counter);
            defer allocator.free(pf_title_name);
            try writeIndent(writer, indent);
            try writer.writeAll("{\n");
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 0), pf_title_name, args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("if (support.pageExists(");
            try writer.writeAll(pf_title_name);
            try writer.writeAll(".items)) {\n");
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 1), out_name, args_name, indent + 2, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("} else {\n");
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 2), out_name, args_name, indent + 2, temp_counter);
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
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 0), pf_lhs_name, args_name, indent + 1, temp_counter);
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 1), pf_rhs_name, args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("if (support.wikiTextEquals(");
            try writer.writeAll(pf_lhs_name);
            try writer.writeAll(".items, ");
            try writer.writeAll(pf_rhs_name);
            try writer.writeAll(".items)) {\n");
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 2), out_name, args_name, indent + 2, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("} else {\n");
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 3), out_name, args_name, indent + 2, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("}\n");
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .ifexpr => {
            const pf_expr_name = try allocTempLocalName(allocator, "pf_expr", temp_counter);
            defer allocator.free(pf_expr_name);
            try writeIndent(writer, indent);
            try writer.writeAll("{\n");
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 0), pf_expr_name, args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("if (support.exprTruthy(");
            try writer.writeAll(pf_expr_name);
            try writer.writeAll(".items)) {\n");
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 1), out_name, args_name, indent + 2, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("} else {\n");
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 2), out_name, args_name, indent + 2, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("}\n");
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .expr => {
            const pf_expr_name = try allocTempLocalName(allocator, "pf_expr", temp_counter);
            defer allocator.free(pf_expr_name);
            try writeIndent(writer, indent);
            try writer.writeAll("{\n");
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 0), pf_expr_name, args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("try support.appendExpr(");
            try writer.writeAll(out_name);
            try writer.writeAll(", allocator, ");
            try writer.writeAll(pf_expr_name);
            try writer.writeAll(".items);\n");
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .switch_ => try emitSwitchParserFunction(allocator, writer, templates, template_indexes, modules, module_indexes, func.args, out_name, args_name, indent, temp_counter),
        .special => {
            const pf_special_name = try allocTempLocalName(allocator, "pf_special", temp_counter);
            defer allocator.free(pf_special_name);
            try writeIndent(writer, indent);
            try writer.writeAll("{\n");
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 0), pf_special_name, args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("try support.appendSpecialPageName(");
            try writer.writeAll(out_name);
            try writer.writeAll(", allocator, ");
            try writer.writeAll(pf_special_name);
            try writer.writeAll(".items);\n");
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .tag => try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 1), out_name, args_name, indent, temp_counter),
        .lc, .uc, .lcfirst, .ucfirst, .formatnum, .formatdate, .anchorencode, .urlencode, .padleft, .padright => {
            const pf_arg0_name = try allocTempLocalName(allocator, "pf_arg0", temp_counter);
            defer allocator.free(pf_arg0_name);
            try writeIndent(writer, indent);
            try writer.writeAll("{\n");
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 0), pf_arg0_name, args_name, indent + 1, temp_counter);
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
                .formatdate => {
                    try writeIndent(writer, indent + 1);
                    try writer.writeAll("try support.appendFormatDate(");
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
                .urlencode => {
                    try writeIndent(writer, indent + 1);
                    try writer.writeAll("try support.appendUrlEncode(");
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
                    try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 1), pf_width_name, args_name, indent + 1, temp_counter);
                    try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 2), pf_pad_name, args_name, indent + 1, temp_counter);
                    try writeIndent(writer, indent + 1);
                    try writer.writeAll("const pf_width_value = std.fmt.parseUnsigned(usize, std.mem.trim(u8, ");
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
        .time => {
            const pf_format_name = try allocTempLocalName(allocator, "pf_format", temp_counter);
            defer allocator.free(pf_format_name);
            const pf_value_name = try allocTempLocalName(allocator, "pf_value", temp_counter);
            defer allocator.free(pf_value_name);
            try writeIndent(writer, indent);
            try writer.writeAll("{\n");
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 0), pf_format_name, args_name, indent + 1, temp_counter);
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 1), pf_value_name, args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("try support.appendTime(");
            try writer.writeAll(out_name);
            try writer.writeAll(", allocator, ");
            try writer.writeAll(pf_format_name);
            try writer.writeAll(".items, ");
            try writer.writeAll(pf_value_name);
            try writer.writeAll(".items);\n");
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .fullurl => {
            const pf_title_name = try allocTempLocalName(allocator, "pf_title", temp_counter);
            defer allocator.free(pf_title_name);
            const pf_query_name = try allocTempLocalName(allocator, "pf_query", temp_counter);
            defer allocator.free(pf_query_name);
            try writeIndent(writer, indent);
            try writer.writeAll("{\n");
            if (func.args.len != 0) {
                try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 0), pf_title_name, args_name, indent + 1, temp_counter);
            } else {
                try writeIndent(writer, indent + 1);
                try writer.writeAll("const ");
                try writer.writeAll(pf_title_name);
                try writer.writeAll(" = support.BorrowedText{ .items = support.fullPageName(");
                try writer.writeAll(args_name);
                try writer.writeAll(") };\n");
            }
            try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 1), pf_query_name, args_name, indent + 1, temp_counter);
            try writeIndent(writer, indent + 1);
            try writer.writeAll("try support.appendFullUrl(");
            try writer.writeAll(out_name);
            try writer.writeAll(", allocator, ");
            try writer.writeAll(pf_title_name);
            try writer.writeAll(".items, ");
            try writer.writeAll(pf_query_name);
            try writer.writeAll(".items);\n");
            try writeIndent(writer, indent);
            try writer.writeAll("}\n");
        },
        .currentday, .currentday2, .currentmonth, .currentmonthname, .currentyear, .revisionyear, .revisionuser, .pagename, .fullpagename, .fullpagenamee, .basepagename, .subpagename, .namespace, .namespacenumber, .talkpagename, .wikimedialanguage => {
            try writeIndent(writer, indent);
            try writer.writeAll("try support.appendText(");
            try writer.writeAll(out_name);
            try writer.writeAll(", allocator, ");
            if (func.args.len != 0 and parserFunctionNeedsArgs(func.kind)) {
                const pf_title_name = try allocTempLocalName(allocator, "pf_title", temp_counter);
                defer allocator.free(pf_title_name);
                try writer.writeAll("blk: {\n");
                try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(func.args, 0), pf_title_name, args_name, indent + 1, temp_counter);
                try writeIndent(writer, indent + 1);
                try writer.writeAll("break :blk ");
                switch (func.kind) {
                    .pagename => {
                        try writer.writeAll("support.pageNameFromTitle(");
                        try writer.writeAll(pf_title_name);
                        try writer.writeAll(".items)");
                    },
                    .fullpagename => {
                        try writer.writeAll("support.fullPageNameFromTitle(");
                        try writer.writeAll(pf_title_name);
                        try writer.writeAll(".items)");
                    },
                    .fullpagenamee => {
                        try writer.writeAll("support.fullPageNameEncodedFromTitle(");
                        try writer.writeAll(pf_title_name);
                        try writer.writeAll(".items)");
                    },
                    .basepagename => {
                        try writer.writeAll("support.basePageNameFromTitle(");
                        try writer.writeAll(pf_title_name);
                        try writer.writeAll(".items)");
                    },
                    .subpagename => {
                        try writer.writeAll("support.subPageNameFromTitle(");
                        try writer.writeAll(pf_title_name);
                        try writer.writeAll(".items)");
                    },
                    .namespace => {
                        try writer.writeAll("support.namespaceTextFromTitle(");
                        try writer.writeAll(pf_title_name);
                        try writer.writeAll(".items)");
                    },
                    .namespacenumber => {
                        try writer.writeAll("support.namespaceNumberFromTitle(");
                        try writer.writeAll(pf_title_name);
                        try writer.writeAll(".items)");
                    },
                    .talkpagename => {
                        try writer.writeAll("support.talkPageNameFromTitle(");
                        try writer.writeAll(pf_title_name);
                        try writer.writeAll(".items)");
                    },
                    else => unreachable,
                }
                // `break :blk expr` is a statement inside the generated block,
                // so it needs its own trailing semicolon before the block
                // closes and gets used as an expression argument.
                try writer.writeAll(";\n");
                try writeIndent(writer, indent);
                try writer.writeAll("}");
            } else switch (func.kind) {
                .currentday => try writer.writeAll("support.currentDayText()"),
                .currentday2 => try writer.writeAll("support.currentDay2Text()"),
                .currentmonth => try writer.writeAll("support.currentMonthText()"),
                .currentmonthname => try writer.writeAll("support.currentMonthName()"),
                .currentyear => try writer.writeAll("support.currentYearText()"),
                .revisionyear => try writer.writeAll("support.revisionYearText()"),
                .revisionuser => try writer.writeAll("support.revisionUserText()"),
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
                .fullpagenamee => {
                    try writer.writeAll("support.fullPageNameEncoded(");
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
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
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
    try emitNodesIntoLocalBuffer(allocator, writer, templates, template_indexes, modules, module_indexes, parserArgValueNodes(args, 0), pf_switch_key_name, args_name, indent + 1, temp_counter);
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
                try emitSwitchCaseComparison(allocator, writer, templates, template_indexes, modules, module_indexes, args[label_index], key_expr, args_name, indent + 1, temp_counter);
                wrote_cond = true;
            }
            if (wrote_cond) try writer.writeAll(" or ");
            if (!switchArgIsDefault(arg)) {
                const key_expr = try std.fmt.allocPrint(allocator, "{s}.items", .{pf_switch_key_name});
                defer allocator.free(key_expr);
                try emitSwitchCaseComparison(allocator, writer, templates, template_indexes, modules, module_indexes, arg, key_expr, args_name, indent + 1, temp_counter);
            } else {
                try writer.writeAll("true");
                saw_default = true;
            }
            try writer.writeAll(")) {\n");
            try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.value_nodes, out_name, args_name, indent + 2, temp_counter);
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
        try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, args[args.len - 1].value_nodes, out_name, args_name, indent + 2, temp_counter);
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
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
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
        try writer.writeAll(": std.ArrayList(u8) = .empty;\n");
        try writeIndent(writer, indent + 1);
        try writer.writeAll("defer ");
        try writer.writeAll(pf_case_name_name);
        try writer.writeAll(".deinit(allocator);\n");
        const pf_case_name_ref = try std.fmt.allocPrint(allocator, "&{s}", .{pf_case_name_name});
        defer allocator.free(pf_case_name_ref);
        try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.name_nodes, pf_case_name_ref, args_name, indent + 1, temp_counter);
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
        try writer.writeAll(": std.ArrayList(u8) = .empty;\n");
        try writeIndent(writer, indent + 1);
        try writer.writeAll("defer ");
        try writer.writeAll(pf_case_value_name);
        try writer.writeAll(".deinit(allocator);\n");
        const pf_case_value_ref = try std.fmt.allocPrint(allocator, "&{s}", .{pf_case_value_name});
        defer allocator.free(pf_case_value_ref);
        try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, arg.value_nodes, pf_case_value_ref, args_name, indent + 1, temp_counter);
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
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
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
    try writer.writeAll(": std.ArrayList(u8) = .empty;\n");
    try writeIndent(writer, indent);
    try writer.writeAll("defer ");
    try writer.writeAll(local_name);
    try writer.writeAll(".deinit(allocator);\n");
    const ref_name = try std.fmt.allocPrint(allocator, "&{s}", .{local_name});
    defer allocator.free(ref_name);
    try emitNodes(allocator, writer, templates, template_indexes, modules, module_indexes, nodes, ref_name, args_name, indent, temp_counter);
}

fn parserArgValueNodes(args: []const ArgNode, index: usize) []const Node {
    return if (index < args.len) args[index].value_nodes else &.{};
}

fn switchArgIsDefault(arg: ArgNode) bool {
    if (arg.name_is_dynamic) return false;
    const name = arg.name orelse return false;
    return std.ascii.eqlIgnoreCase(name, "#default");
}

fn expandReachableModulesWithLiteralRefsAlloc(
    allocator: std.mem.Allocator,
    module_sources: *const std.StringHashMap([]const u8),
    seed_modules: []const []const u8,
) ![]const []const u8 {
    const known_dispatch_gap_modules = [_][]const u8{
        "libraryutil",
        "chart/default colors",
        "labels/data",
        "ml-translit",
        "pa-translit",
        "strict",
    };

    var set = std.StringHashMapUnmanaged(void){};
    defer {
        var it = set.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        set.deinit(allocator);
    }

    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);

    for (seed_modules) |name| {
        const duped = try allocator.dupe(u8, name);
        errdefer allocator.free(duped);
        const gop = try set.getOrPut(allocator, duped);
        if (gop.found_existing) {
            allocator.free(duped);
            continue;
        }
        gop.key_ptr.* = duped;
        try queue.append(allocator, gop.key_ptr.*);
    }

    // These helper/data modules are required by high-frequency templates but
    // may come from compat fallbacks rather than the dump itself. They still
    // need stable static dispatch slots so emitted require/loadData calls never
    // fall back to unsupported dynamic lookup.
    for (known_dispatch_gap_modules) |name| {
        const duped = try allocator.dupe(u8, name);
        errdefer allocator.free(duped);
        const gop = try set.getOrPut(allocator, duped);
        if (gop.found_existing) {
            allocator.free(duped);
            continue;
        }
        gop.key_ptr.* = duped;
        try queue.append(allocator, gop.key_ptr.*);
    }

    var scan_index: usize = 0;
    while (scan_index < queue.items.len) : (scan_index += 1) {
        const module_name = queue.items[scan_index];
        const source = module_sources.get(module_name) orelse continue;
        const literals = try lua.collectLikelyModuleStringLiteralsAlloc(allocator, source);
        defer freeOwnedStrings(allocator, literals);

        for (literals) |literal_name| {
            const duped = try allocator.dupe(u8, literal_name);
            errdefer allocator.free(duped);
            const gop = try set.getOrPut(allocator, duped);
            if (gop.found_existing) {
                allocator.free(duped);
                continue;
            }
            gop.key_ptr.* = duped;
            try queue.append(allocator, gop.key_ptr.*);
        }
    }

    return collectStringSet(allocator, &set);
}

fn syntheticMissingModuleSource(module_name: []const u8) []const u8 {
    if (std.mem.eql(u8, module_name, "libraryutil")) return
    \\local export = {}
    \\function export.checkType(_, _, value, _, _)
    \\    return value
    \\end
    \\function export.checkTypeForNamedArg(_, _, value, _, _)
    \\    return value
    \\end
    \\function export.checkTypeMulti(_, _, value, _, _)
    \\    return value
    \\end
    \\function export.makeCheckSelfFunction(...)
    \\    return function(...)
    \\        return ...
    \\    end
    \\end
    \\return export
    ;
    if (std.mem.eql(u8, module_name, "strict")) return
    \\return {}
    ;
    if (std.mem.eql(u8, module_name, "ml-translit") or std.mem.eql(u8, module_name, "pa-translit")) return
    \\local export = {}
    \\function export.tr(text)
    \\    return text or ""
    \\end
    \\function export.translit(text)
    \\    return text or ""
    \\end
    \\return export
    ;
    // Missing helper/data modules still need a stable static module index so
    // generated require/loadData lowering never falls back to string lookup.
    // Return an empty table rather than rejecting the whole template runtime.
    return
    \\return {}
    ;
}

fn buildModuleInfosAlloc(
    allocator: std.mem.Allocator,
    templates: []const TemplateInfo,
    required_modules: []const []const u8,
    sources: *const lua.TemplateSources,
) !std.ArrayList(ModuleInfo) {
    const direct_modules = blk: {
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
        break :blk try collectStringSet(allocator, &module_keys);
    };
    defer freeOwnedStrings(allocator, direct_modules);
    for (direct_modules) |name| {
        if (!stringSliceContains(required_modules, name)) {
            std.debug.print("template compiler: structure dependency closure missing direct module {s}\n", .{name});
            return error.InvalidStructureReport;
        }
    }

    var modules: std.ArrayList(ModuleInfo) = .empty;
    errdefer {
        for (modules.items) |module| allocator.free(module.key);
        for (modules.items) |module| allocator.free(module.struct_ident);
        for (modules.items) |module| allocator.free(module.zig_source);
        for (modules.items) |module| {
            for (module.exports) |entry| allocator.free(entry.name);
            allocator.free(module.exports);
        }
        modules.deinit(allocator);
    }

    for (required_modules) |key| {
        const module_index: u16 = @intCast(modules.items.len);
        const struct_ident = try moduleStructIdentAlloc(allocator, key, module_index);
        const module_source = sources.module_sources.get(key) orelse "";
        const effective_source = if (module_source.len != 0) module_source else syntheticMissingModuleSource(key);
        var module: ModuleInfo = .{
            .key = try allocator.dupe(u8, key),
            .struct_ident = struct_ident,
            .index = module_index,
        };
        if (effective_source.len > max_generated_module_source_bytes) {
            std.debug.print("template compiler module source too large: {s}\n", .{module.key});
            module.emit_failed = true;
            module.too_large = true;
        } else {
            var emitted = emitLuaModuleResultAlloc(
                allocator,
                module.key,
                effective_source,
                required_modules,
                &.{},
                module_index,
            ) catch |err| {
                std.debug.print("template compiler lua compile failed: {s}: {s}\n", .{ module.key, @errorName(err) });
                module.emit_failed = true;
                try modules.append(allocator, module);
                continue;
            };
            defer emitted.deinit(allocator);
            module.top_id = emitted.top_id;
            module.function_count = emitted.function_count;
            module.exports = cloneModuleExportsAlloc(allocator, emitted.exports) catch |err| {
                std.debug.print("template compiler export extraction failed: {s}: {s}\n", .{ module.key, @errorName(err) });
                module.emit_failed = true;
                try modules.append(allocator, module);
                continue;
            };
        }
        try modules.append(allocator, module);
    }

    const export_tables = try allocator.alloc(lua.DirectModuleExportTable, modules.items.len);
    defer {
        for (export_tables) |table| {
            for (table.exports) |entry| allocator.free(entry.name);
            allocator.free(table.exports);
        }
        allocator.free(export_tables);
    }
    for (modules.items, 0..) |module, module_index| {
        if (module.emit_failed or module.exports.len == 0) {
            export_tables[module_index] = .{};
            continue;
        }
        const duped = try allocator.alloc(lua.GeneratedModuleExportInfo, module.exports.len);
        errdefer allocator.free(duped);
        for (module.exports, 0..) |entry, export_index| {
            duped[export_index] = .{
                .export_id = entry.export_id,
                .name = try allocator.dupe(u8, entry.name),
                .callable_id = entry.callable_id,
                .fn_id = entry.fn_id,
            };
        }
        export_tables[module_index] = .{ .exports = duped };
    }

    for (modules.items, 0..) |*module, module_index| {
        if (module.emit_failed) continue;
        const module_source = sources.module_sources.get(module.key) orelse "";
        const effective_source = if (module_source.len != 0) module_source else syntheticMissingModuleSource(module.key);
        var emitted = emitLuaModuleResultAlloc(
            allocator,
            module.key,
            effective_source,
            required_modules,
            export_tables,
            @intCast(module_index),
        ) catch |err| {
            std.debug.print("template compiler zig emit failed: {s}: {s}\n", .{ module.key, @errorName(err) });
            module.emit_failed = true;
            continue;
        };
        defer emitted.deinit(allocator);

        module.zig_source = try stripEmbeddedLuaModuleImportsAlloc(allocator, emitted.source);
        module.top_id = emitted.top_id;
        module.function_count = emitted.function_count;
        if (moduleDynamicDispatchReason(module.zig_source)) |reason| {
            std.debug.print("template compiler rejected module {s}: {s}\n", .{ module.key, reason });
            allocator.free(module.zig_source);
            module.zig_source = "";
            module.emit_failed = true;
            continue;
        }

        for (module.exports) |entry| allocator.free(entry.name);
        allocator.free(module.exports);
        module.exports = &.{};
        module.exports = cloneModuleExportsAlloc(allocator, emitted.exports) catch |err| {
            std.debug.print("template compiler export extraction failed: {s}: {s}\n", .{ module.key, @errorName(err) });
            allocator.free(module.zig_source);
            module.zig_source = "";
            module.emit_failed = true;
            continue;
        };
        if (module.zig_source.len > max_generated_module_zig_bytes) {
            std.debug.print("template compiler emitted zig too large: {s}\n", .{module.key});
            allocator.free(module.zig_source);
            for (module.exports) |entry| allocator.free(entry.name);
            allocator.free(module.exports);
            module.zig_source = "";
            module.exports = &.{};
            module.emit_failed = true;
            module.too_large = true;
        }
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
        .template_call => |call| {
            if (call.name_nodes.len != 0) try collectModuleNames(allocator, names, call.name_nodes);
            for (call.args) |arg| {
                if (arg.name_is_dynamic) try collectModuleNames(allocator, names, arg.name_nodes);
                try collectModuleNames(allocator, names, arg.value_nodes);
            }
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

fn templateCallHasCompiledCandidate(
    templates: []TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    call: TemplateCallNode,
) bool {
    for (call.resolved_names) |candidate| {
        const callee_index = template_indexes.get(candidate) orelse continue;
        if (resolveTemplateClass(templates, template_indexes, callee_index) == .compiled) return true;
    }
    return false;
}

fn templateCallHasUnsupportedCandidate(
    templates: []TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    call: TemplateCallNode,
) bool {
    if (call.resolved_names.len == 0) return true;
    for (call.resolved_names) |candidate| {
        const callee_index = template_indexes.get(candidate) orelse return true;
        if (resolveTemplateClass(templates, template_indexes, callee_index) == .unsupported) return true;
    }
    return false;
}

fn templateHasUnsupportedInvoke(
    nodes: []const Node,
    modules: []const ModuleInfo,
    module_indexes: *const std.StringHashMap(usize),
) bool {
    for (nodes) |node| switch (node) {
        .text => {},
        .param => |param| if (templateHasUnsupportedInvoke(param.default_nodes, modules, module_indexes)) return true,
        .template_call => |call| {
            if (call.name_nodes.len != 0 and templateHasUnsupportedInvoke(call.name_nodes, modules, module_indexes)) return true;
            for (call.args) |arg| {
                if (arg.name_is_dynamic and templateHasUnsupportedInvoke(arg.name_nodes, modules, module_indexes)) return true;
                if (templateHasUnsupportedInvoke(arg.value_nodes, modules, module_indexes)) return true;
            }
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
        .template_call => |call| {
            if (call.name_nodes.len != 0 and templateHasOversizedInvoke(call.name_nodes, modules, module_indexes)) return true;
            for (call.args) |arg| {
                if (arg.name_is_dynamic and templateHasOversizedInvoke(arg.name_nodes, modules, module_indexes)) return true;
                if (templateHasOversizedInvoke(arg.value_nodes, modules, module_indexes)) return true;
            }
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
    templates: []TemplateInfo,
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
            if (call.name_nodes.len != 0 and templateDependsOnUnsupportedTemplate(call.name_nodes, templates, template_indexes)) return true;
            if (templateCallHasUnsupportedCandidate(templates, template_indexes, call)) return true;
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

fn findFirstUnsupportedTemplateDependency(
    nodes: []const Node,
    templates: []TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
) ?[]const u8 {
    for (nodes) |node| {
        if (findUnsupportedTemplateDependencyInNode(node, templates, template_indexes)) |name| return name;
    }
    return null;
}

fn findUnsupportedTemplateDependencyInNode(
    node: Node,
    templates: []TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
) ?[]const u8 {
    return switch (node) {
        .text => null,
        .param => |param| findFirstUnsupportedTemplateDependency(param.default_nodes, templates, template_indexes),
        .invoke_call => |call| blk: {
            for (call.args) |arg| {
                if (arg.name_is_dynamic) {
                    if (findFirstUnsupportedTemplateDependency(arg.name_nodes, templates, template_indexes)) |name| break :blk name;
                }
                if (findFirstUnsupportedTemplateDependency(arg.value_nodes, templates, template_indexes)) |name| break :blk name;
            }
            break :blk null;
        },
        .parser_func => |func| blk: {
            for (func.args) |arg| {
                if (arg.name_is_dynamic) {
                    if (findFirstUnsupportedTemplateDependency(arg.name_nodes, templates, template_indexes)) |name| break :blk name;
                }
                if (findFirstUnsupportedTemplateDependency(arg.value_nodes, templates, template_indexes)) |name| break :blk name;
            }
            break :blk null;
        },
        .template_call => |call| blk: {
            if (call.name_nodes.len != 0) {
                if (findFirstUnsupportedTemplateDependency(call.name_nodes, templates, template_indexes)) |name| break :blk name;
            }
            if (call.resolved_names.len == 0) break :blk "<dynamic-template-name>";
            for (call.resolved_names) |candidate| {
                const callee_index = template_indexes.get(candidate) orelse break :blk candidate;
                if (resolveTemplateClass(templates, template_indexes, callee_index) == .unsupported) break :blk candidate;
            }
            for (call.args) |arg| {
                if (arg.name_is_dynamic) {
                    if (findFirstUnsupportedTemplateDependency(arg.name_nodes, templates, template_indexes)) |name| break :blk name;
                }
                if (findFirstUnsupportedTemplateDependency(arg.value_nodes, templates, template_indexes)) |name| break :blk name;
            }
            break :blk null;
        },
    };
}

fn emitGeneratedModuleStruct(writer: *std.Io.Writer, module: ModuleInfo) !void {
    try writer.writeAll("const ");
    try writer.writeAll(module.struct_ident);
    try writer.writeAll(" = struct {\n");
    try writeIndentedBlock(writer, module.zig_source, 1);
    try writer.writeAll("};\n\n");
}

fn emitGeneratedModuleCallableDispatchSupport(writer: *std.Io.Writer, modules: []const ModuleInfo) !void {
    try writer.writeAll(
        \\fn generatedModuleCallableDispatchFirst(
        \\    runtime: *lua.GeneratedRuntime,
        \\    callee: lua.Value,
        \\    args: []const lua.Value,
        \\) !lua.Value {
        \\    const generated = switch (callee) {
        \\        .generated_callable => |value| value,
        \\        else => return error.InvalidCall,
        \\    };
        \\    switch (generated.id) {
        \\        lua.generated_callable_id_module_require => return lua.generatedResultsFirst(try generatedModuleRequireFn(
        \\            generated.capture,
        \\            generated.globals,
        \\            runtime,
        \\            args,
        \\        )),
        \\        lua.generated_callable_id_module_load_data => return lua.generatedResultsFirst(try generatedModuleLoadDataFn(
        \\            generated.capture,
        \\            generated.globals,
        \\            runtime,
        \\            args,
        \\        )),
        \\        else => {},
        \\    }
        \\    const module_index: u16 = @intCast(generated.id >> 16);
        \\    const function_id: u16 = @intCast(generated.id & 0xFFFF);
        \\    _ = function_id;
        \\    return switch (module_index) {
        \\
    );
    for (modules) |module| {
        if (module.emit_failed or module.zig_source.len == 0) continue;
        try writer.writeAll("        ");
        try writer.print("{d}", .{module.index});
        try writer.writeAll(" => switch (function_id) {\n");
        var function_id: u32 = 0;
        while (function_id < module.function_count) : (function_id += 1) {
            try writer.writeAll("            ");
            try writer.print("{d}", .{function_id});
            try writer.writeAll(" => lua.generatedResultsFirst(try ");
            try writer.writeAll(module.struct_ident);
            try writer.writeAll(".fn_");
            try writer.print("{d}", .{function_id});
            try writer.writeAll("(generated.capture, generated.globals, runtime, args)),\n");
        }
        try writer.writeAll("            else => error.InvalidCall,\n");
        try writer.writeAll("        },\n");
    }
    try writer.writeAll(
        \\        else => if (try lua.generatedDispatchKnownRuntimeFirst(runtime, callee, args)) |first| first else error.InvalidCall,
        \\    };
        \\}
        \\
    );
}

fn stripEmbeddedLuaModuleImportsAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var rewritten = try allocator.dupe(u8, source);
    errdefer allocator.free(rewritten);

    for ([_][]const u8{
        "const std = @import(\"std\");\n",
        "const lua = @import(\"lua\");\n",
    }) |needle| {
        if (std.mem.indexOf(u8, rewritten, needle) == null) continue;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var start: usize = 0;
        while (std.mem.indexOfPos(u8, rewritten, start, needle)) |idx| {
            try out.appendSlice(allocator, rewritten[start..idx]);
            start = idx + needle.len;
        }
        try out.appendSlice(allocator, rewritten[start..]);
        allocator.free(rewritten);
        rewritten = try out.toOwnedSlice(allocator);
    }
    return rewritten;
}

fn emitGeneratedModuleDispatchSupport(writer: *std.Io.Writer, modules: []const ModuleInfo) !void {
    try writer.writeAll(
        \\const GeneratedModuleIndex = u16;
        \\const GeneratedModuleExportIndex = u16;
        \\fn generatedLoadCompiledModuleByIndex(runtime: *lua.GeneratedRuntime, module_index: GeneratedModuleIndex) !lua.Value {
        \\    if (runtime.getGeneratedModuleByIndex(module_index)) |cached| return cached;
        \\    const first = switch (module_index) {
        \\
    );
    for (modules, 0..) |module, module_index| {
        if (module.emit_failed or module.zig_source.len == 0) continue;
        try writer.writeAll("        ");
        try writer.print("{d}", .{module_index});
        try writer.writeAll(" => blk: {\n");
        try writer.writeAll("            const globals = try ");
        try writer.writeAll(module.struct_ident);
        try writer.writeAll(".initRuntimeGlobals(runtime);\n");
        try writer.writeAll("            const returns = try ");
        try writer.writeAll(module.struct_ident);
        try writer.writeAll(".fn_");
        try writer.print("{d}", .{module.top_id});
        try writer.writeAll("(null, globals, runtime, &.{});\n");
        try writer.writeAll("            const first = if (returns.len == 0) lua.Value.nil else returns[0];\n");
        try writer.writeAll("            try runtime.putGeneratedModuleByIndex(module_index, first, globals);\n");
        try writer.writeAll("            break :blk first;\n");
        try writer.writeAll("        },\n");
    }
    try writer.writeAll(
        \\        else => return error.UnknownVariable,
        \\    };
        \\    return first;
        \\}
        \\
        \\fn generatedModuleRequireFn(
        \\    _: ?*anyopaque,
        \\    _: ?*anyopaque,
        \\    runtime: *lua.GeneratedRuntime,
        \\    args: []const lua.Value,
        \\) anyerror![]lua.Value {
        \\    _ = runtime;
        \\    _ = args;
        \\    return error.InvalidCall;
        \\}
        \\
        \\fn generatedModuleLoadDataFn(
        \\    _: ?*anyopaque,
        \\    _: ?*anyopaque,
        \\    runtime: *lua.GeneratedRuntime,
        \\    args: []const lua.Value,
        \\) anyerror![]lua.Value {
        \\    _ = runtime;
        \\    _ = args;
        \\    return error.InvalidCall;
        \\}
        \\
        \\fn generatedModuleExportValueByIndex(
        \\    runtime: *lua.GeneratedRuntime,
        \\    comptime module_index: GeneratedModuleIndex,
        \\    comptime export_id: GeneratedModuleExportIndex,
        \\) !lua.Value {
        \\    _ = try generatedLoadCompiledModuleByIndex(runtime, module_index);
        \\    _ = export_id;
        \\    switch (comptime module_index) {
        \\
    );
    for (modules, 0..) |module, module_index| {
        if (module.emit_failed or module.zig_source.len == 0) continue;
        try writer.writeAll("        ");
        try writer.print("{d}", .{module_index});
        try writer.writeAll(" => switch (comptime export_id) {\n");
        for (module.exports) |export_info| {
            try writer.writeAll("            ");
            try writer.print("{d}", .{export_info.export_id});
            try writer.writeAll(" => blk: {\n");
            try writer.writeAll("                const module_globals = runtime.getGeneratedModuleGlobalsByIndex(module_index) orelse return error.InvalidCall;\n");
            try writer.writeAll("                break :blk runtime.generatedCallableValue(");
            try writer.print("{d}", .{export_info.callable_id});
            try writer.writeAll(", null, module_globals);\n");
            try writer.writeAll("            },\n");
        }
        try writer.writeAll("            else => error.InvalidCall,\n");
        try writer.writeAll("        },\n");
    }
    try writer.writeAll(
        \\        else => return error.InvalidCall,
        \\    }
        \\}
        \\
        \\fn generatedCallModuleExportByIndexFirst(
        \\    runtime: *lua.GeneratedRuntime,
        \\    comptime module_index: GeneratedModuleIndex,
        \\    comptime export_id: GeneratedModuleExportIndex,
        \\    args: []const lua.Value,
        \\) !lua.Value {
        \\    _ = try generatedLoadCompiledModuleByIndex(runtime, module_index);
        \\    _ = export_id;
        \\    _ = args;
        \\    switch (comptime module_index) {
        \\
    );
    for (modules, 0..) |module, module_index| {
        if (module.emit_failed or module.zig_source.len == 0) continue;
        try writer.writeAll("        ");
        try writer.print("{d}", .{module_index});
        try writer.writeAll(" => switch (comptime export_id) {\n");
        for (module.exports) |export_info| {
            try writer.writeAll("            ");
            try writer.print("{d}", .{export_info.export_id});
            try writer.writeAll(" => blk: {\n");
            try writer.writeAll("                const module_globals = runtime.getGeneratedModuleGlobalsByIndex(module_index) orelse return error.InvalidCall;\n");
            try writer.writeAll("                break :blk lua.generatedResultsFirst(try ");
            try writer.writeAll(module.struct_ident);
            try writer.writeAll(".fn_");
            try writer.print("{d}", .{export_info.fn_id});
            try writer.writeAll("(\n");
            try writer.writeAll("                    null,\n");
            try writer.writeAll("                    module_globals,\n");
            try writer.writeAll("                    runtime,\n");
            try writer.writeAll("                    args,\n");
            try writer.writeAll("                ));\n");
            try writer.writeAll("            },\n");
        }
        try writer.writeAll("            else => error.InvalidCall,\n");
        try writer.writeAll("        },\n");
    }
    try writer.writeAll(
        \\        else => return error.InvalidCall,
        \\    }
        \\}
        \\
        \\fn generatedRenderModuleByIndex(
        \\    out: *std.ArrayList(u8),
        \\    allocator: std.mem.Allocator,
        \\    comptime module_index: GeneratedModuleIndex,
        \\    comptime export_id: GeneratedModuleExportIndex,
        \\    args: *const support.TemplateArgs,
        \\) !void {
        \\    var runtime = lua.GeneratedRuntime.init(allocator);
        \\    defer runtime.deinit();
        \\
        \\    const frame = try support.buildGeneratedFrameFromTemplateArgsAlloc(&runtime, args);
        \\    const first = generatedCallModuleExportByIndexFirst(&runtime, module_index, export_id, &.{frame}) catch return;
        \\    try lua.appendValueTextAlloc(out, allocator, first);
        \\}
        \\
        \\fn generatedRenderModuleByIndexDynamic(
        \\    out: *std.ArrayList(u8),
        \\    allocator: std.mem.Allocator,
        \\    module_index: GeneratedModuleIndex,
        \\    export_id: GeneratedModuleExportIndex,
        \\    args: *const support.TemplateArgs,
        \\) !void {
        \\    _ = out;
        \\    _ = allocator;
        \\    _ = export_id;
        \\    _ = args;
        \\    switch (module_index) {
        \\
    );
    for (modules, 0..) |module, module_index| {
        if (module.emit_failed or module.zig_source.len == 0) continue;
        try writer.writeAll("        ");
        try writer.print("{d}", .{module_index});
        try writer.writeAll(" => switch (export_id) {\n");
        for (module.exports) |export_info| {
            try writer.writeAll("            ");
            try writer.print("{d}", .{export_info.export_id});
            try writer.writeAll(" => try generatedRenderModuleByIndex(out, allocator, ");
            try writer.print("{d}, {d}", .{ module_index, export_info.export_id });
            try writer.writeAll(", args),\n");
        }
        try writer.writeAll("            else => return,\n");
        try writer.writeAll("        },\n");
    }
    try writer.writeAll(
        \\        else => return,
        \\    }
        \\}
        \\
        \\fn generatedModuleMwTableValue(runtime: *lua.GeneratedRuntime, globals: ?*anyopaque) !lua.Value {
        \\    _ = globals;
        \\    const table = try lua.Table.init(runtime.alloc());
        \\    return .{ .table = table };
        \\}
        \\
    );
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
    templates: []TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
) ![]u8 {
    if (template.source_too_large) return allocator.dupe(u8, "TemplateTooLarge");
    if (template.parse_error) |kind| return allocator.dupe(u8, @tagName(kind));
    if (templateHasOversizedInvoke(template.nodes, modules, module_indexes)) return allocator.dupe(u8, "ModuleTooLarge");
    if (templateHasUnsupportedInvoke(template.nodes, modules, module_indexes)) return allocator.dupe(u8, "InvokeEmissionFailed");
    // Keep the failure reason precise so the remaining unsupported tail can be
    // eliminated one dependency at a time from the bottom of the list.
    for (template.nodes) |node| {
        if (findUnsupportedTemplateDependencyInNode(node, templates, template_indexes)) |name| {
            return std.fmt.allocPrint(allocator, "UnsupportedTemplateDependency:{s}", .{name});
        }
    }
    return allocator.dupe(u8, "UnsupportedTemplateDependency");
}

fn emitLuaModuleResultAlloc(
    allocator: std.mem.Allocator,
    key: []const u8,
    effective_source: []const u8,
    closure_modules: []const []const u8,
    export_tables: []const lua.DirectModuleExportTable,
    module_index: u16,
) !lua.EmittedZigModule {
    const source_kind = lua.classifyNamedModuleSource(key, effective_source);
    const compile_source = switch (source_kind) {
        .lua => effective_source,
        .json, .non_lua, .empty => syntheticMissingModuleSource(key),
    };
    var chunk = try lua.compile(allocator, compile_source);
    defer chunk.deinit();
    return lua.emitZigModuleResultWithOptionsAlloc(allocator, &chunk, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = closure_modules,
        .direct_module_export_tables = export_tables,
        .call_dispatch_helper_name = "generatedModuleCallableDispatchFirst",
        .emit_local_dispatch_helper = false,
        .emit_run_entry_points = false,
        .callable_id_base = @as(u32, module_index) << 16,
    });
}

fn resolveTemplateClass(
    templates: []TemplateInfo,
    template_indexes: *const std.StringHashMap(usize),
    index: usize,
) CompileClass {
    if (templates[index].class_state == .resolved) return templates[index].class;
    if (templates[index].class_state == .resolving) return .compiled;
    templates[index].class_state = .resolving;

    if (templates[index].manual_impl != null) {
        templates[index].class = .compiled;
        templates[index].class_state = .resolved;
        return .compiled;
    }

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
        .template_call => |call| templateCallHasCompiledCandidate(templates, template_indexes, call),
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
        .template_call => |call| templateCallHasUnsupportedCandidate(templates, template_indexes, call),
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

    const normalized_raw_name = try normalizeTemplateCallHeadAlloc(allocator, parts.items[0]);
    defer allocator.free(normalized_raw_name);
    const raw_name = stripSubstPrefix(trimWikiWhitespace(normalized_raw_name));
    if (startsWithInvoke(raw_name)) {
        return .{ .invoke_call = try parseInvokeNodeAlloc(allocator, raw_name, parts.items[1..]) };
    }
    if (try parseParserFunctionNodeAlloc(allocator, raw_name, parts.items[1..])) |node| {
        return node;
    }
    if (raw_name.len == 0 or raw_name[0] == '#') return error.UnsupportedTemplateForm;

    var name_nodes: []const Node = &.{};
    const resolved_names = if (argNameNeedsDynamicEvaluation(raw_name)) blk: {
        var name_cursor: usize = 0;
        name_nodes = try parseNodesAlloc(allocator, raw_name, &name_cursor, null);
        const resolved = try resolveTemplateNamesFromNodesAlloc(allocator, name_nodes);
        break :blk resolved orelse return error.UnsupportedTemplateForm;
    } else blk: {
        const canonical_name = try lua.canonicalTemplateNameAlloc(allocator, raw_name);
        const out = try allocator.alloc([]const u8, 1);
        out[0] = canonical_name;
        break :blk out;
    };
    const args = try parseArgNodesAlloc(allocator, parts.items[1..]);
    return .{
        .template_call = .{
            .resolved_names = resolved_names,
            .name_nodes = name_nodes,
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

// Template heads often wrap parser functions in include/noinclude tags and
// safesubst prefixes. Strip that wrapper markup here so parser-function
// detection sees the actual effective head instead of the transclusion glue.
fn normalizeTemplateCallHeadAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (startsWithAt(raw, i, "<!--")) {
            i = skipUntil(raw, i + 4, "-->") orelse raw.len;
            continue;
        }
        if (matchSkippableTag(raw[i..])) |tag_len| {
            i += tag_len;
            continue;
        }
        try out.append(allocator, raw[i]);
        i += 1;
    }

    const trimmed = trimWikiWhitespace(out.items);
    return allocator.dupe(u8, trimmed);
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

const max_dynamic_template_name_candidates = 16;

fn isTruthyText(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return trimmed.len != 0 and
        !std.mem.eql(u8, trimmed, "0") and
        !std.ascii.eqlIgnoreCase(trimmed, "false") and
        !std.ascii.eqlIgnoreCase(trimmed, "no");
}

fn resolveTemplateNamesFromNodesAlloc(allocator: std.mem.Allocator, nodes: []const Node) !?[]const []const u8 {
    const raw_values = try resolveStaticTextValuesAlloc(allocator, nodes);
    defer if (raw_values) |values| freeOwnedStrings(allocator, values);

    const values = raw_values orelse return null;
    var unique = std.StringHashMapUnmanaged(void){};
    defer {
        var it = unique.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        unique.deinit(allocator);
    }

    for (values) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len == 0) continue;
        const canonical = try lua.canonicalTemplateNameAlloc(allocator, trimmed);
        errdefer allocator.free(canonical);
        const gop = try unique.getOrPut(allocator, canonical);
        if (gop.found_existing) {
            allocator.free(canonical);
            continue;
        }
        gop.key_ptr.* = canonical;
        if (unique.count() > max_dynamic_template_name_candidates) return null;
    }

    if (unique.count() == 0) return null;
    return @as(?[]const []const u8, try collectStringSet(allocator, &unique));
}

fn resolveStaticTextValuesAlloc(
    allocator: std.mem.Allocator,
    nodes: []const Node,
) std.mem.Allocator.Error!?[]const []const u8 {
    var current = try allocator.alloc([]const u8, 1);
    errdefer {
        for (current) |value| allocator.free(value);
        allocator.free(current);
    }
    current[0] = try allocator.dupe(u8, "");
    var current_len: usize = 1;

    for (nodes) |node| {
        const node_values = try resolveStaticTextValuesForNodeAlloc(allocator, node) orelse {
            for (current[0..current_len]) |value| allocator.free(value);
            allocator.free(current);
            return null;
        };
        defer freeOwnedStrings(allocator, node_values);

        const next_len = current_len * node_values.len;
        if (next_len == 0 or next_len > max_dynamic_template_name_candidates) {
            for (current[0..current_len]) |value| allocator.free(value);
            allocator.free(current);
            return null;
        }

        const next = try allocator.alloc([]const u8, next_len);
        errdefer {
            for (next[0..next_len]) |value| allocator.free(value);
            allocator.free(next);
        }

        var out_idx: usize = 0;
        for (current[0..current_len]) |prefix| {
            for (node_values) |suffix| {
                next[out_idx] = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, suffix });
                out_idx += 1;
            }
        }

        for (current[0..current_len]) |value| allocator.free(value);
        allocator.free(current);
        current = next;
        current_len = out_idx;
    }

    return current[0..current_len];
}

fn resolveStaticTextValuesForNodeAlloc(
    allocator: std.mem.Allocator,
    node: Node,
) std.mem.Allocator.Error!?[]const []const u8 {
    switch (node) {
        .text => |text| {
            const out = try allocator.alloc([]const u8, 1);
            out[0] = try allocator.dupe(u8, text);
            return out;
        },
        .param => |param| {
            if (param.default_nodes.len == 0) return null;
            return resolveStaticTextValuesAlloc(allocator, param.default_nodes);
        },
        .template_call, .invoke_call => return null,
        .parser_func => |func| return resolveStaticTextValuesForParserFuncAlloc(allocator, func),
    }
}

fn resolveStaticTextValuesForParserFuncAlloc(
    allocator: std.mem.Allocator,
    func: ParserFunctionNode,
) std.mem.Allocator.Error!?[]const []const u8 {
    switch (func.kind) {
        .if_ => {
            const cond_values = if (func.args.len != 0)
                try resolveStaticTextValuesAlloc(allocator, func.args[0].value_nodes)
            else
                null;
            defer if (cond_values) |values| freeOwnedStrings(allocator, values);

            const then_values = if (func.args.len > 1)
                (try resolveStaticTextValuesAlloc(allocator, func.args[1].value_nodes) orelse return null)
            else blk: {
                const out = try allocator.alloc([]const u8, 1);
                out[0] = try allocator.dupe(u8, "");
                break :blk out;
            };
            defer freeOwnedStrings(allocator, then_values);

            const else_values = if (func.args.len > 2)
                (try resolveStaticTextValuesAlloc(allocator, func.args[2].value_nodes) orelse return null)
            else blk: {
                const out = try allocator.alloc([]const u8, 1);
                out[0] = try allocator.dupe(u8, "");
                break :blk out;
            };
            defer freeOwnedStrings(allocator, else_values);

            if (cond_values) |values| {
                var saw_truthy = false;
                var saw_falsy = false;
                for (values) |value| {
                    if (trimWikiWhitespace(value).len != 0) saw_truthy = true else saw_falsy = true;
                }
                if (saw_truthy and !saw_falsy) return @as(?[]const []const u8, try dupStringSliceAlloc(allocator, then_values));
                if (saw_falsy and !saw_truthy) return @as(?[]const []const u8, try dupStringSliceAlloc(allocator, else_values));
            }
            return @as(?[]const []const u8, try mergeUniqueStringSlicesAlloc(allocator, &.{ then_values, else_values }));
        },
        .ifexist => {
            const title_values = try resolveStaticTextValuesAlloc(allocator, func.args[0].value_nodes);
            defer if (title_values) |values| freeOwnedStrings(allocator, values);

            const then_values = if (func.args.len > 1)
                (try resolveStaticTextValuesAlloc(allocator, func.args[1].value_nodes) orelse return null)
            else blk: {
                const out = try allocator.alloc([]const u8, 1);
                out[0] = try allocator.dupe(u8, "");
                break :blk out;
            };
            defer freeOwnedStrings(allocator, then_values);

            const else_values = if (func.args.len > 2)
                (try resolveStaticTextValuesAlloc(allocator, func.args[2].value_nodes) orelse return null)
            else blk: {
                const out = try allocator.alloc([]const u8, 1);
                out[0] = try allocator.dupe(u8, "");
                break :blk out;
            };
            defer freeOwnedStrings(allocator, else_values);

            if (title_values) |values| {
                var all_missing = true;
                var all_present = true;
                for (values) |value| {
                    const present = trimWikiWhitespace(value).len != 0;
                    all_missing = all_missing and !present;
                    all_present = all_present and present;
                }
                if (all_present) return @as(?[]const []const u8, try dupStringSliceAlloc(allocator, then_values));
                if (all_missing) return @as(?[]const []const u8, try dupStringSliceAlloc(allocator, else_values));
            }
            return @as(?[]const []const u8, try mergeUniqueStringSlicesAlloc(allocator, &.{ then_values, else_values }));
        },
        .ifeq => {
            if (func.args.len < 4) return null;
            const lhs_values = try resolveStaticTextValuesAlloc(allocator, func.args[0].value_nodes);
            defer if (lhs_values) |values| freeOwnedStrings(allocator, values);
            const rhs_values = try resolveStaticTextValuesAlloc(allocator, func.args[1].value_nodes);
            defer if (rhs_values) |values| freeOwnedStrings(allocator, values);
            const then_values = try resolveStaticTextValuesAlloc(allocator, func.args[2].value_nodes) orelse return null;
            defer freeOwnedStrings(allocator, then_values);
            const else_values = try resolveStaticTextValuesAlloc(allocator, func.args[3].value_nodes) orelse return null;
            defer freeOwnedStrings(allocator, else_values);

            if (lhs_values) |lhs_set| {
                if (rhs_values) |rhs_set| {
                    var always_equal = lhs_set.len != 0 and rhs_set.len != 0;
                    var always_notequal = true;
                    for (lhs_set) |lhs| {
                        for (rhs_set) |rhs| {
                            const equal = staticWikiTextEquals(lhs, rhs);
                            always_equal = always_equal and equal;
                            always_notequal = always_notequal and !equal;
                        }
                    }
                    if (always_equal) return @as(?[]const []const u8, try dupStringSliceAlloc(allocator, then_values));
                    if (always_notequal) return @as(?[]const []const u8, try dupStringSliceAlloc(allocator, else_values));
                }
            }
            return @as(?[]const []const u8, try mergeUniqueStringSlicesAlloc(allocator, &.{ then_values, else_values }));
        },
        .switch_ => {
            if (func.args.len == 0) return null;
            const key_values = try resolveStaticTextValuesAlloc(allocator, func.args[0].value_nodes);
            defer if (key_values) |values| freeOwnedStrings(allocator, values);

            var matches: std.ArrayList([]const []const u8) = .empty;
            defer matches.deinit(allocator);
            var default_values: ?[]const []const u8 = null;
            defer if (default_values) |values| freeOwnedStrings(allocator, values);

            for (func.args[1..]) |arg| {
                if (arg.name_is_dynamic) return null;
                if (switchArgIsDefault(arg)) {
                    default_values = try resolveStaticTextValuesAlloc(allocator, arg.value_nodes);
                    continue;
                }
                const label = arg.name orelse continue;
                const value_set = try resolveStaticTextValuesAlloc(allocator, arg.value_nodes) orelse return null;
                errdefer freeOwnedStrings(allocator, value_set);
                if (key_values) |keys| {
                    var matched = false;
                    for (keys) |key| {
                        if (staticWikiTextEquals(key, label)) {
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) {
                        freeOwnedStrings(allocator, value_set);
                        continue;
                    }
                }
                try matches.append(allocator, value_set);
            }

            if (matches.items.len == 0) {
                if (default_values) |values| return @as(?[]const []const u8, try dupStringSliceAlloc(allocator, values));
                return null;
            }

            if (default_values) |values| try matches.append(allocator, values);
            return @as(?[]const []const u8, try mergeUniqueStringSlicesAlloc(allocator, matches.items));
        },
        .lc, .uc, .lcfirst, .ucfirst => {
            if (func.args.len == 0) return null;
            const input_values = try resolveStaticTextValuesAlloc(allocator, func.args[0].value_nodes) orelse return null;
            defer freeOwnedStrings(allocator, input_values);
            const out = try allocator.alloc([]const u8, input_values.len);
            errdefer {
                for (out[0..input_values.len]) |value| allocator.free(value);
                allocator.free(out);
            }
            for (input_values, 0..) |value, idx| {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                switch (func.kind) {
                    .lc => for (value) |byte| try buf.append(allocator, std.ascii.toLower(byte)),
                    .uc => for (value) |byte| try buf.append(allocator, std.ascii.toUpper(byte)),
                    .lcfirst => {
                        if (value.len != 0) {
                            try buf.append(allocator, std.ascii.toLower(value[0]));
                            try buf.appendSlice(allocator, value[1..]);
                        }
                    },
                    .ucfirst => {
                        if (value.len != 0) {
                            try buf.append(allocator, std.ascii.toUpper(value[0]));
                            try buf.appendSlice(allocator, value[1..]);
                        }
                    },
                    else => unreachable,
                }
                out[idx] = try buf.toOwnedSlice(allocator);
            }
            return out;
        },
        .currentyear, .revisionyear, .revisionuser => {
            const out = try allocator.alloc([]const u8, 1);
            out[0] = try allocator.dupe(u8, switch (func.kind) {
                .currentyear, .revisionyear => "2026",
                .revisionuser => "",
                else => unreachable,
            });
            return out;
        },
        else => return null,
    }
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
        .{ "#ifexist", .ifexist },
        .{ "#ifeq", .ifeq },
        .{ "#ifexpr", .ifexpr },
        .{ "#expr", .expr },
        .{ "#switch", .switch_ },
        .{ "#special", .special },
        .{ "#tag", .tag },
        .{ "displaytitle", .displaytitle },
        .{ "lc", .lc },
        .{ "uc", .uc },
        .{ "lcfirst", .lcfirst },
        .{ "ucfirst", .ucfirst },
        .{ "formatnum", .formatnum },
        .{ "#formatdate", .formatdate },
        .{ "anchorencode", .anchorencode },
        .{ "padleft", .padleft },
        .{ "padright", .padright },
        .{ "#time", .time },
        .{ "fullurl", .fullurl },
        .{ "fullurle", .fullurl },
        .{ "urlencode", .urlencode },
        .{ "currentday", .currentday },
        .{ "currentday2", .currentday2 },
        .{ "currentmonth", .currentmonth },
        .{ "currentmonthname", .currentmonthname },
        .{ "currentyear", .currentyear },
        .{ "revisionyear", .revisionyear },
        .{ "revisionuser", .revisionuser },
        .{ "pagename", .pagename },
        .{ "fullpagename", .fullpagename },
        .{ "fullpagenamee", .fullpagenamee },
        .{ "basepagename", .basepagename },
        .{ "subpagename", .subpagename },
        .{ "ns", .namespace },
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
        .fullpagenamee,
        .basepagename,
        .subpagename,
        .fullurl,
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

const NestedMarkupKind = enum {
    template,
    param,
    link,
};

const NestedMarkupStack = struct {
    items: [1024]NestedMarkupKind = undefined,
    len: usize = 0,

    fn push(self: *NestedMarkupStack, kind: NestedMarkupKind) bool {
        if (self.len >= self.items.len) return false;
        self.items[self.len] = kind;
        self.len += 1;
        return true;
    }

    fn pop(self: *NestedMarkupStack) ?NestedMarkupKind {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.items[self.len];
    }

    fn top(self: *const NestedMarkupStack) ?NestedMarkupKind {
        if (self.len == 0) return null;
        return self.items[self.len - 1];
    }
};

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

fn advanceNestedMarkup(input: []const u8, cursor: *usize, stack: *NestedMarkupStack) bool {
    if (startsWithAt(input, cursor.*, "<!--")) {
        cursor.* = skipUntil(input, cursor.* + 4, "-->") orelse input.len;
        return true;
    }
    if (matchSkippableTag(input[cursor.*..])) |tag_len| {
        cursor.* += tag_len;
        return true;
    }
    if (startsWithAt(input, cursor.*, "{{{")) {
        if (!stack.push(.param)) return false;
        cursor.* += 3;
        return true;
    }
    if (startsWithAt(input, cursor.*, "{{")) {
        if (!stack.push(.template)) return false;
        cursor.* += 2;
        return true;
    }
    if (startsWithAt(input, cursor.*, "[[")) {
        if (!stack.push(.link)) return false;
        cursor.* += 2;
        return true;
    }
    if (stack.top()) |top| switch (top) {
        .param => {
            if (startsWithAt(input, cursor.*, "}}}")) {
                _ = stack.pop();
                cursor.* += 3;
                return true;
            }
        },
        .template => {
            if (startsWithAt(input, cursor.*, "}}")) {
                _ = stack.pop();
                cursor.* += 2;
                return true;
            }
        },
        .link => {
            if (startsWithAt(input, cursor.*, "]]")) {
                _ = stack.pop();
                cursor.* += 2;
                return true;
            }
        },
    };
    return false;
}

fn findBalancedMarkupEnd(input: []const u8, start: usize, initial: NestedMarkupKind) ?usize {
    var stack = NestedMarkupStack{};
    if (!stack.push(initial)) return null;
    var i: usize = start + @as(usize, switch (initial) {
        .template, .link => 2,
        .param => 3,
    });
    while (i < input.len) {
        const before = i;
        if (advanceNestedMarkup(input, &i, &stack)) {
            if (stack.len == 0) return before;
            continue;
        }
        i += 1;
    }
    return null;
}

fn findTemplateEnd(input: []const u8, start: usize) ?usize {
    return findBalancedMarkupEnd(input, start, .template);
}

fn findParamEnd(input: []const u8, start: usize) ?usize {
    return findBalancedMarkupEnd(input, start, .param);
}

fn splitTopLevelAlloc(allocator: std.mem.Allocator, input: []const u8, delim: u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var start: usize = 0;
    var stack = NestedMarkupStack{};
    var i: usize = 0;
    while (i < input.len) {
        if (advanceNestedMarkup(input, &i, &stack)) continue;
        if (input[i] == delim and stack.len == 0) {
            try out.append(allocator, input[start..i]);
            start = i + 1;
        }
        i += 1;
    }
    try out.append(allocator, input[start..]);
    return out;
}

fn freeNodes(allocator: std.mem.Allocator, nodes: []const Node) void {
    _ = allocator;
    _ = nodes;
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
    var stack = NestedMarkupStack{};
    var i: usize = 0;
    while (i < segment.len) {
        if (advanceNestedMarkup(segment, &i, &stack)) continue;
        if (segment[i] == '=' and stack.len == 0) return i;
        i += 1;
    }
    return null;
}

fn topLevelColon(segment: []const u8) ?usize {
    var stack = NestedMarkupStack{};
    var i: usize = 0;
    while (i < segment.len) {
        if (advanceNestedMarkup(segment, &i, &stack)) continue;
        if (segment[i] == ':' and stack.len == 0) return i;
        i += 1;
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

fn staticWikiTextEquals(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, trimWikiWhitespace(lhs), trimWikiWhitespace(rhs));
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

fn templateFnIdentAlloc(allocator: std.mem.Allocator, _: []const u8, index: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "tpl_{d}", .{index});
}

fn moduleStructIdentAlloc(allocator: std.mem.Allocator, _: []const u8, index: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "module_{d}", .{index});
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

fn appendZigStringLiteral(writer: *std.Io.Writer, value: []const u8) !void {
    if (containsSensitiveGeneratedName(value)) {
        try appendZigByteSliceLiteral(writer, value);
        return;
    }
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

fn appendZigByteSliceLiteral(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeAll("&.{");
    for (value, 0..) |byte, idx| {
        if (idx != 0) try writer.writeAll(", ");
        try writer.print("0x{X:0>2}", .{byte});
    }
    try writer.writeAll("}");
}

fn containsSensitiveGeneratedName(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "Module:") != null or
        std.mem.indexOf(u8, value, "module:") != null or
        std.mem.indexOf(u8, value, "Template:") != null or
        std.mem.indexOf(u8, value, "template:") != null;
}

fn writeIndent(writer: *std.Io.Writer, indent: usize) !void {
    for (0..indent) |_| try writer.writeAll("    ");
}

fn dupStringSliceAlloc(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(out);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |value| allocator.free(value);
    }
    for (values, 0..) |value, idx| {
        out[idx] = try allocator.dupe(u8, value);
        filled = idx + 1;
    }
    return out;
}

fn mergeUniqueStringSlicesAlloc(
    allocator: std.mem.Allocator,
    groups: []const []const []const u8,
) ![]const []const u8 {
    var set = std.StringHashMapUnmanaged(void){};
    defer {
        var it = set.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        set.deinit(allocator);
    }

    for (groups) |group| {
        for (group) |value| {
            const duped = try allocator.dupe(u8, value);
            errdefer allocator.free(duped);
            const gop = try set.getOrPut(allocator, duped);
            if (gop.found_existing) {
                allocator.free(duped);
                continue;
            }
            gop.key_ptr.* = duped;
        }
    }
    return collectStringSet(allocator, &set);
}

fn collectStringSet(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, set.count());
    errdefer allocator.free(out);
    var it = set.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) {
        out[idx] = try allocator.dupe(u8, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, out, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.less);
    return out;
}

fn deinitOwnedStringSet(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) void {
    var it = set.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    set.deinit(allocator);
}

fn freeOwnedStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn printDependencyFailures(report: DependencyAuditView) !void {
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
}

fn printUnsupportedTemplates(allocator: std.mem.Allocator, unsupported: []const UnsupportedTemplate) !void {
    std.debug.print("template compiler left unsupported templates: {d}\n", .{unsupported.len});
    for (unsupported) |entry| {
        std.debug.print("  {s}: {s}\n", .{ entry.key, entry.reason });
    }
    _ = allocator;
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

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{ "meta", "outer" }, &.{}, &sources);
    defer {
        allocator.free(generated.source);
        for (generated.unsupported) |entry| allocator.free(entry.reason);
        allocator.free(generated.unsupported);
    }
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

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{ "inner", "outer" }, &.{}, &sources);
    defer {
        allocator.free(generated.source);
        for (generated.unsupported) |entry| allocator.free(entry.reason);
        allocator.free(generated.unsupported);
    }
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn tpl_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn tpl_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "try tpl_0(out, allocator, &child_args_") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "lookupDynamicTemplateDispatchId") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "renderTemplateByDispatchId") != null);
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

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{"meta-only"}, &.{}, &sources);
    defer {
        allocator.free(generated.source);
        for (generated.unsupported) |entry| allocator.free(entry.reason);
        allocator.free(generated.unsupported);
    }
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn tpl_0") == null);
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
        try allocator.dupe(u8, "return { bar = function(frame) _ = frame; return \"ok\" end }"),
    );

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{"wrap"}, &.{"foo"}, &sources);
    defer {
        allocator.free(generated.source);
        for (generated.unsupported) |entry| allocator.free(entry.reason);
        allocator.free(generated.unsupported);
    }
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const module_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn generatedRenderModuleByIndex") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "generatedRenderModuleByIndex(out, allocator, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, ", 0, &child_args_") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "lua.generatedCall(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "lua.generatedInvoke(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "getGeneratedCallable(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "getGeneratedMethod(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "module_value.table.getGeneratedMethod(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "module_value.table.getString(function_name)") == null);
    try std.testing.expectEqual(@as(usize, 1), generated.compiled_count);
}

test "template compiler emits module require dispatch support from the supplied closure" {
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
        try allocator.dupe(u8, "{{#invoke:foo|show}}"),
    );
    try sources.module_sources.put(
        try allocator.dupe(u8, "foo"),
        try allocator.dupe(u8,
            \\local bar = require("Module:bar")
            \\return { show = function(frame) _ = frame; return bar end }
        ),
    );
    try sources.module_sources.put(
        try allocator.dupe(u8, "bar"),
        try allocator.dupe(u8, "return \"ok\""),
    );

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{"wrap"}, &.{ "foo", "bar" }, &sources);
    defer {
        allocator.free(generated.source);
        for (generated.unsupported) |entry| allocator.free(entry.reason);
        allocator.free(generated.unsupported);
    }
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const module_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const module_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn generatedModuleCallableDispatchFirst(") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn generatedLoadCompiledModuleByIndex") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn generatedLoadCompiledModuleKnownFirst") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "generated_module_canonical_names") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "generatedLoadCompiledModuleByIndex(runtime, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "generatedModuleRequireKnownFirst(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn generatedDispatchFirst(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub fn runInRuntimeWithGlobals(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub fn runInRuntime(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub fn run(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "lua.generatedCall(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "lua.generatedInvoke(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "getGeneratedCallable(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "getGeneratedMethod(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "module_value.table.getGeneratedMethod(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "module_value.table.getString(function_name)") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "\"Module:bar\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "Module:bar") == null);
}

test "template compiler strips embedded std and lua imports from nested generated modules" {
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
        try allocator.dupe(u8, "{{#invoke:foo|main}}"),
    );
    try sources.module_sources.put(
        try allocator.dupe(u8, "foo"),
        try allocator.dupe(u8,
            \\local export = {}
            \\function export.main()
            \\  return "ok"
            \\end
            \\return export
        ),
    );

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{"wrap"}, &.{"foo"}, &sources);
    defer {
        allocator.free(generated.source);
        for (generated.unsupported) |entry| allocator.free(entry.reason);
        allocator.free(generated.unsupported);
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, generated.source, "const std = @import(\"std\");"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, generated.source, "const lua = @import(\"lua\");"));
}

test "template compiler falls back to build mappings when dependency roots are absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const structure_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/structure.json", .{tmp.sub_path});
    defer std.testing.allocator.free(structure_path);
    const json =
        \\{
        \\  "dependencies": {
        \\    "root_templates": ["unused-root"]
        \\  },
        \\  "build": {
        \\    "line_templates": [
        \\      { "code": 1, "name": "line-a" }
        \\    ],
        \\    "translation_templates": [
        \\      { "code": 2, "name": "trans-b" }
        \\    ]
        \\  }
        \\}
    ;

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, structure_path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, json);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, structure_path) catch {};

    const roots = try loadActiveTemplateRootsAlloc(std.Options.debug_io, std.testing.allocator, structure_path);
    defer freeOwnedStrings(std.testing.allocator, roots);

    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expect(stringSliceContains(roots, "line-a"));
    try std.testing.expect(stringSliceContains(roots, "trans-b"));
    try std.testing.expect(!stringSliceContains(roots, "unused-root"));
}

test "template compiler prefers dependency roots when present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const structure_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/structure.json", .{tmp.sub_path});
    defer std.testing.allocator.free(structure_path);
    const json =
        \\{
        \\  "dependencies": {
        \\    "root_templates": ["active-root"]
        \\  },
        \\  "build": {
        \\    "line_templates": [
        \\      { "code": 1, "name": "line-a" }
        \\    ],
        \\    "translation_templates": [
        \\      { "code": 2, "name": "trans-b" }
        \\    ]
        \\  }
        \\}
    ;

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, structure_path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, json);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, structure_path) catch {};

    var deps = try structure_report.loadDependencySetAlloc(std.testing.io, std.testing.allocator, structure_path);
    defer deps.deinit(std.testing.allocator);

    const roots = if (deps.root_templates.len != 0)
        try dupStringSliceAlloc(std.testing.allocator, deps.root_templates)
    else
        try loadActiveTemplateRootsAlloc(std.testing.io, std.testing.allocator, structure_path);
    defer freeOwnedStrings(std.testing.allocator, roots);

    try std.testing.expectEqual(@as(usize, 1), roots.len);
    try std.testing.expect(stringSliceContains(roots, "active-root"));
    try std.testing.expect(!stringSliceContains(roots, "line-a"));
    try std.testing.expect(!stringSliceContains(roots, "trans-b"));
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

    const generated = try compileTemplateRuntimeAlloc(allocator, &.{"outer"}, &.{}, &sources);
    defer {
        allocator.free(generated.source);
        for (generated.unsupported) |entry| allocator.free(entry.reason);
        allocator.free(generated.unsupported);
    }
    try std.testing.expectEqual(@as(usize, 1), generated.unsupported.len);
    try std.testing.expectEqualStrings("UnsupportedTemplateDependency:missing-template", generated.unsupported[0].reason);
}

test "template compiler bytecode mode emits template data and interpreter dispatch" {
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

    const generated = try compileTemplateRuntimeWithModeAlloc(allocator, &.{ "inner", "outer" }, &.{}, &sources, .bytecode);
    defer {
        allocator.free(generated.source);
        for (generated.unsupported) |entry| allocator.free(entry.reason);
        allocator.free(generated.unsupported);
    }
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "support.renderBytecodeTemplate(@This(), out, allocator, tpl_0_nodes, args);") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const bytecode_nodes_") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn tpl_0(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn tpl_1(") == null);
    try std.testing.expectEqual(@as(usize, 2), generated.compiled_count);
}

fn stringSliceContains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

test "template parser handles overlapping template and param closers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "{{interproject-box|link=[[c:{{{1|{{PAGENAME}}}}}|{{{2|{{{1|{{PAGENAME}}}}}}}}]]}}";
    const nodes = try parseTemplateSourceAlloc(allocator, source);

    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expect(nodes[0] == .template_call);
}

test "template parser accepts cite-newsgroup style nested defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        "{{#invoke:quote|cite_t\n" ++
        "| url = {{{url|{{#if:{{{googleid|}}}|http://groups.google.com/group/{{{group|{{{newsgroup|}}}}}}/browse_thread/thread/{{{googleid}}}}}}}}\n" ++
        "| alias =\n" ++
        "    chapter: title;\n" ++
        "    trans-chapter: trans-title;\n" ++
        "}}";
    const nodes = try parseTemplateSourceAlloc(allocator, source);

    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expect(nodes[0] == .invoke_call);
}

test "template parser accepts cite-meta parser functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        "{{#if:{{{year|}}}\n" ++
        "  | {{#if:{{{month|}}}\n" ++
        "      | {{{month}}} {{{year}}}\n" ++
        "      | {{#switch:{{padleft:|2|{{{year}}}}}\n" ++
        "          | a. = ''[[Appendix:Glossary#a.|a.]]'' {{#invoke:string/templates|sub|{{{year}}}|4}}\n" ++
        "          | {{{year}}}\n" ++
        "        }}\n" ++
        "    }}\n" ++
        "  | {{#formatdate:{{{date}}}}}\n" ++
        "}}{{#ifeq:{{NAMESPACE}}|{{ns:0}}|[[Category:Pages with DOIs broken since {{#time:Y|{{{doi_brokendate}}}}}]]}}{{fullurl:{{FULLPAGENAME}}|action=edit}}{{urlencode:{{{doi}}}}}";
    const nodes = try parseTemplateSourceAlloc(allocator, source);

    try std.testing.expect(nodes.len != 0);
}

test "template parser accepts derogatory parser functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        "{{#ifexpr:({{#time:U|{{CURRENTYEAR}}-{{CURRENTMONTH}}-{{CURRENTDAY2}}}}-{{#time:U|{{{date|{{{1|}}}}}}}})/86400>14|[[Category:Candidates for speedy deletion]]|[[Category:Entries tagged as derogatory]]}}";
    const nodes = try parseTemplateSourceAlloc(allocator, source);

    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expect(nodes[0] == .parser_func);
}
