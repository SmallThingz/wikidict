const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const structure_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const keep_translations = b.option(bool, "keep-translations", "Keep Translations sections in the generated dictionary") orelse false;
    const config_options = b.addOptions();
    config_options.addOption(bool, "keep_translations", keep_translations);
    const generated_tables = addGeneratedStructureTableModules(b, target, optimize, structure_optimize);

    const zxml_dep = b.dependency("zxml", .{
        .target = target,
        .optimize = optimize,
    });
    const zxml_dep_structure = b.dependency("zxml", .{
        .target = target,
        .optimize = structure_optimize,
    });
    const zhttp_dep = b.dependency("zhttp", .{
        .target = target,
        .optimize = optimize,
    });
    const normalize_mod = b.createModule(.{
        .root_source_file = b.path("decoder/normalize.zig"),
        .target = target,
        .optimize = optimize,
    });
    const normalize_mod_structure = b.createModule(.{
        .root_source_file = b.path("decoder/normalize.zig"),
        .target = target,
        .optimize = structure_optimize,
    });

    const encoder_mod = b.addModule("encoder", .{
        .root_source_file = b.path("encoder/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    encoder_mod.addOptions("config", config_options);
    encoder_mod.addImport("normalize", normalize_mod);
    encoder_mod.addImport("zxml", zxml_dep.module("zxml"));
    encoder_mod.addImport("generated_structure_tables", generated_tables.regular);
    const encoder_mod_structure = b.addModule("encoder_structure", .{
        .root_source_file = b.path("encoder/root.zig"),
        .target = target,
        .optimize = structure_optimize,
    });
    encoder_mod_structure.addOptions("config", config_options);
    encoder_mod_structure.addImport("normalize", normalize_mod_structure);
    encoder_mod_structure.addImport("zxml", zxml_dep_structure.module("zxml"));
    encoder_mod_structure.addImport("generated_structure_tables", generated_tables.structure);

    const decoder_mod = b.addModule("decoder", .{
        .root_source_file = b.path("decoder/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    decoder_mod.addImport("normalize", normalize_mod);
    decoder_mod.addImport("encoder", encoder_mod);

    const backend_mod = b.addModule("backend", .{
        .root_source_file = b.path("backend/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend_mod.addImport("encoder", encoder_mod);
    backend_mod.addImport("decoder", decoder_mod);
    backend_mod.addImport("zhttp", zhttp_dep.module("zhttp"));

    const encoder_exe = addCliExecutable(b, "dict-encoder", b.path("encoder/main.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = encoder_mod },
    });
    const decoder_exe = addCliExecutable(b, "dict-decoder", b.path("decoder/main.zig"), target, optimize, &.{
        .{ .name = "decoder", .module = decoder_mod },
    });
    const backend_exe = addCliExecutable(b, "dict-backend", b.path("backend/main.zig"), target, optimize, &.{
        .{ .name = "backend", .module = backend_mod },
    });
    const structure_exe = addCliExecutable(b, "dict-structure", b.path("tools/structure_analyzer.zig"), target, structure_optimize, &.{
        .{ .name = "encoder", .module = encoder_mod_structure },
        .{ .name = "zxml", .module = zxml_dep_structure.module("zxml") },
    });
    const verifier_exe = addCliExecutable(b, "dict-verify", b.path("tools/verifier.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = encoder_mod },
        .{ .name = "decoder", .module = decoder_mod },
        .{ .name = "zxml", .module = zxml_dep.module("zxml") },
    });

    b.installArtifact(encoder_exe);
    b.installArtifact(decoder_exe);
    b.installArtifact(backend_exe);
    b.installArtifact(structure_exe);
    b.installArtifact(verifier_exe);

    addRunStep(b, "encode", "Run the encoder CLI", encoder_exe, &.{});
    addRunStep(b, "decode", "Run the decoder CLI", decoder_exe, &.{});
    addRunStep(b, "serve", "Run the backend server", backend_exe, &.{});
    addRunStep(b, "structure", "Analyze Wiktionary structure", structure_exe, &.{});
    addRunStep(b, "verify", "Verify dictionary raw entries against the XML dump", verifier_exe, &.{});

    addFrontendStep(b);

    const test_runner = b.path("tools/test_runner.zig");

    const encoder_tests = b.addTest(.{
        .root_module = encoder_mod,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const decoder_tests = b.addTest(.{
        .root_module = decoder_mod,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const backend_tests = b.addTest(.{
        .root_module = backend_mod,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const structure_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/structure_analyzer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "encoder", .module = encoder_mod },
                .{ .name = "zxml", .module = zxml_dep.module("zxml") },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const verifier_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/verifier.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "encoder", .module = encoder_mod },
                .{ .name = "decoder", .module = decoder_mod },
                .{ .name = "zxml", .module = zxml_dep.module("zxml") },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });

    const run_encoder_tests = b.addRunArtifact(encoder_tests);
    const run_decoder_tests = b.addRunArtifact(decoder_tests);
    const run_backend_tests = b.addRunArtifact(backend_tests);
    const run_structure_tests = b.addRunArtifact(structure_tests);
    const run_verifier_tests = b.addRunArtifact(verifier_tests);

    const test_step = b.step("test", "Run encoder, decoder, and backend tests");
    test_step.dependOn(&run_encoder_tests.step);
    test_step.dependOn(&run_decoder_tests.step);
    test_step.dependOn(&run_backend_tests.step);
    test_step.dependOn(&run_structure_tests.step);
    test_step.dependOn(&run_verifier_tests.step);
}

fn addCliExecutable(
    b: *std.Build,
    name: []const u8,
    root_source: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = root_source,
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
}

fn addRunStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    exe: *std.Build.Step.Compile,
    fixed_args: []const []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);
    for (fixed_args) |arg| run_cmd.addArg(arg);
    if (b.args) |args| run_cmd.addArgs(args);

    const step = b.step(name, description);
    step.dependOn(&run_cmd.step);
}

fn addFrontendStep(b: *std.Build) void {
    const cmd = b.addSystemCommand(&.{ "bash", "tools/frontend" });
    if (b.args) |args| cmd.addArgs(args);

    const step = b.step("frontend", "Run the frontend CLI in tools/frontend");
    step.dependOn(&cmd.step);
}

const GeneratedStructureModules = struct {
    regular: *std.Build.Module,
    structure: *std.Build.Module,
};

const StructureReport = struct {
    heading_profiles: []const HeadingProfile,
    translation_source_labels: ?[]const CountEntry = null,
    translation_target_languages: ?[]const CountEntry = null,
    templates_by_heading: ?[]const HeadingTemplateEntry = null,
};

const HeadingProfile = struct {
    title: []const u8,
    parser_kind: []const u8,
    count: u64 = 0,
};

const CountEntry = struct {
    key: []const u8,
    count: u64 = 0,
};

const HeadingTemplateEntry = struct {
    heading: []const u8,
    template: []const u8,
    count: u64 = 0,
};

const GeneratedHeading = struct {
    title: []const u8,
    kind_name: []const u8,
    count: u64,
};

const GeneratedLabel = struct {
    label: []const u8,
    count: u64,
};

const GeneratedTemplate = struct {
    name: []const u8,
    count: u64,
};

const GeneratedLineTemplate = struct {
    name: []const u8,
    count: u64,
};

const GeneratedCompactPattern = struct {
    pattern: []const u8,
    count: u64,
};

const GeneratedTargetLanguage = struct {
    value: []const u8,
    count: u64,
};

fn addGeneratedStructureTableModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    structure_optimize: std.builtin.OptimizeMode,
) GeneratedStructureModules {
    const generated_source = generateStructureTableSource(b) catch |err| {
        std.debug.panic("failed to generate structure tables from data/wiktionary-structure.json: {s}", .{@errorName(err)});
    };

    const write_files = b.addWriteFiles();
    const generated_path = write_files.add("generated/structure_tables.zig", generated_source);
    return .{
        .regular = b.createModule(.{
            .root_source_file = generated_path,
            .target = target,
            .optimize = optimize,
        }),
        .structure = b.createModule(.{
            .root_source_file = generated_path,
            .target = target,
            .optimize = structure_optimize,
        }),
    };
}

fn generateStructureTableSource(b: *std.Build) ![]const u8 {
    const allocator = b.allocator;
    const report_path = b.pathFromRoot("data/wiktionary-structure.json");
    const json_bytes = try readFileAllocAbsolute(allocator, report_path, 64 * 1024 * 1024);
    defer allocator.free(json_bytes);

    var parsed = try std.json.parseFromSlice(StructureReport, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var headings: std.ArrayList(GeneratedHeading) = .empty;
    defer headings.deinit(allocator);
    var heading_indexes = std.StringHashMapUnmanaged(usize).empty;
    defer heading_indexes.deinit(allocator);

    for (parsed.value.heading_profiles) |profile| {
        if (std.mem.eql(u8, profile.title, "English")) continue;
        const gop = try heading_indexes.getOrPut(allocator, profile.title);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, profile.title);
            gop.value_ptr.* = headings.items.len;
            try headings.append(allocator, .{
                .title = gop.key_ptr.*,
                .kind_name = sectionKindNameForParser(profile.parser_kind) orelse return error.InvalidStructureReport,
                .count = profile.count,
            });
        } else {
            headings.items[gop.value_ptr.*].count += profile.count;
        }
    }
    std.mem.sortUnstable(GeneratedHeading, headings.items, {}, generatedHeadingLessThan);

    var labels: std.ArrayList(GeneratedLabel) = .empty;
    defer labels.deinit(allocator);
    var label_indexes = std.StringHashMapUnmanaged(usize).empty;
    defer label_indexes.deinit(allocator);
    if (parsed.value.translation_source_labels) |source_labels| {
        for (source_labels) |entry| {
            const label = std.mem.trim(u8, entry.key, " \t\r\n");
            if (label.len == 0) continue;
            const gop = try label_indexes.getOrPut(allocator, label);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, label);
                gop.value_ptr.* = labels.items.len;
                try labels.append(allocator, .{
                    .label = gop.key_ptr.*,
                    .count = entry.count,
                });
            } else {
                labels.items[gop.value_ptr.*].count += entry.count;
            }
        }
    }
    std.mem.sortUnstable(GeneratedLabel, labels.items, {}, generatedLabelLessThan);

    var templates: std.ArrayList(GeneratedTemplate) = .empty;
    defer templates.deinit(allocator);
    var template_indexes = std.StringHashMapUnmanaged(usize).empty;
    defer template_indexes.deinit(allocator);
    var line_templates: std.ArrayList(GeneratedLineTemplate) = .empty;
    defer line_templates.deinit(allocator);
    var line_template_indexes = std.StringHashMapUnmanaged(usize).empty;
    defer line_template_indexes.deinit(allocator);
    if (parsed.value.templates_by_heading) |template_rows| {
        for (template_rows) |entry| {
            const template_name = std.mem.trim(u8, entry.template, " \t\r\n");
            if (template_name.len == 0) continue;
            if (isTranslationHeading(entry.heading)) {
                const gop = try template_indexes.getOrPut(allocator, template_name);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try allocator.dupe(u8, template_name);
                    gop.value_ptr.* = templates.items.len;
                    try templates.append(allocator, .{
                        .name = gop.key_ptr.*,
                        .count = entry.count,
                    });
                } else {
                    templates.items[gop.value_ptr.*].count += entry.count;
                }
                continue;
            }

            const gop = try line_template_indexes.getOrPut(allocator, template_name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, template_name);
                gop.value_ptr.* = line_templates.items.len;
                try line_templates.append(allocator, .{
                    .name = gop.key_ptr.*,
                    .count = entry.count,
                });
            } else {
                line_templates.items[gop.value_ptr.*].count += entry.count;
            }
        }
    }
    std.mem.sortUnstable(GeneratedTemplate, templates.items, {}, generatedTemplateLessThan);
    std.mem.sortUnstable(GeneratedLineTemplate, line_templates.items, {}, generatedLineTemplateLessThan);
    if (line_templates.items.len > 1024) {
        line_templates.shrinkRetainingCapacity(1024);
    }

    var compact_patterns: std.ArrayList(GeneratedCompactPattern) = .empty;
    defer compact_patterns.deinit(allocator);
    var compact_patterns_ext: std.ArrayList(GeneratedCompactPattern) = .empty;
    defer compact_patterns_ext.deinit(allocator);
    var all_compact_patterns: std.ArrayList(GeneratedCompactPattern) = .empty;
    defer all_compact_patterns.deinit(allocator);
    var all_compact_pattern_indexes = std.StringHashMapUnmanaged(usize).empty;
    defer all_compact_pattern_indexes.deinit(allocator);
    for (line_templates.items) |template_entry| {
        const pattern = compactPatternForTemplate(allocator, template_entry.name) orelse continue;
        const gop = try all_compact_pattern_indexes.getOrPut(allocator, pattern);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, pattern);
            gop.value_ptr.* = all_compact_patterns.items.len;
            try all_compact_patterns.append(allocator, .{
                .pattern = gop.key_ptr.*,
                .count = template_entry.count,
            });
        } else {
            all_compact_patterns.items[gop.value_ptr.*].count += template_entry.count;
        }
    }
    std.mem.sortUnstable(GeneratedCompactPattern, all_compact_patterns.items, {}, generatedCompactPatternLessThan);

    var covered_compact_patterns = std.StringHashMapUnmanaged(void).empty;
    defer covered_compact_patterns.deinit(allocator);
    try seedCoveredCompactPatterns(allocator, b.pathFromRoot("encoder/compact_encoding.zig"), &covered_compact_patterns);

    for (all_compact_patterns.items) |pattern_entry| {
        const gop = try covered_compact_patterns.getOrPut(allocator, pattern_entry.pattern);
        if (gop.found_existing) continue;
        gop.key_ptr.* = try allocator.dupe(u8, pattern_entry.pattern);

        if (compact_patterns.items.len < 50) {
            try compact_patterns.append(allocator, pattern_entry);
        } else if (compact_patterns_ext.items.len < 200) {
            try compact_patterns_ext.append(allocator, pattern_entry);
        } else {
            break;
        }
    }

    var target_languages: std.ArrayList(GeneratedTargetLanguage) = .empty;
    defer target_languages.deinit(allocator);
    var target_language_indexes = std.StringHashMapUnmanaged(usize).empty;
    defer target_language_indexes.deinit(allocator);
    if (parsed.value.translation_target_languages) |target_language_rows| {
        for (target_language_rows) |entry| {
            const value = std.mem.trim(u8, entry.key, " \t\r\n");
            if (value.len == 0) continue;
            const gop = try target_language_indexes.getOrPut(allocator, value);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, value);
                gop.value_ptr.* = target_languages.items.len;
                try target_languages.append(allocator, .{
                    .value = gop.key_ptr.*,
                    .count = entry.count,
                });
            } else {
                target_languages.items[gop.value_ptr.*].count += entry.count;
            }
        }
    }
    std.mem.sortUnstable(GeneratedTargetLanguage, target_languages.items, {}, generatedTargetLanguageLessThan);

    if (headings.items.len + 1 > std.math.maxInt(u16)) return error.TooManyGeneratedHeadings;
    if (templates.items.len > std.math.maxInt(u16)) return error.TooManyGeneratedTemplates;
    if (labels.items.len > std.math.maxInt(u16)) return error.TooManyGeneratedLabels;
    if (target_languages.items.len > std.math.maxInt(u16)) return error.TooManyGeneratedTargetLanguages;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll(
        \\// Generated by build.zig from data/wiktionary-structure.json.
        \\const std = @import("std");
        \\
        \\pub const SectionKind = enum(u8) {
        \\    lines = 0,
        \\    pos_lines = 1,
        \\    term_list = 2,
        \\    translations = 3,
        \\};
        \\
        \\pub const HeadingSpec = struct {
        \\    code: u16,
        \\    title: []const u8,
        \\    kind: SectionKind,
        \\};
        \\
        \\pub const heading_specs = [_]HeadingSpec{
        \\
    );

    for (headings.items, 0..) |heading, index| {
        try writer.writeAll("    .{ .code = ");
        try writer.print("{d}", .{index + 2});
        try writer.writeAll(", .title = ");
        try appendZigStringLiteral(writer, heading.title);
        try writer.writeAll(", .kind = .");
        try writer.writeAll(heading.kind_name);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const LineTemplate = struct {
        \\    code: u16,
        \\    name: []const u8,
        \\};
        \\
        \\pub const line_templates = [_]LineTemplate{
        \\
    );
    for (line_templates.items, 0..) |template_entry, index| {
        try writer.writeAll("    .{ .code = ");
        try writer.print("{d}", .{index + 1});
        try writer.writeAll(", .name = ");
        try appendZigStringLiteral(writer, template_entry.name);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const compact_patterns = [_][]const u8{
        \\
    );
    for (compact_patterns.items) |pattern_entry| {
        try writer.writeAll("    ");
        try appendZigStringLiteral(writer, pattern_entry.pattern);
        try writer.writeAll(",\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const compact_patterns_ext = [_][]const u8{
        \\
    );
    for (compact_patterns_ext.items) |pattern_entry| {
        try writer.writeAll("    ");
        try appendZigStringLiteral(writer, pattern_entry.pattern);
        try writer.writeAll(",\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const TranslationTemplate = struct {
        \\    code: u16,
        \\    name: []const u8,
        \\};
        \\
        \\pub const translation_templates = [_]TranslationTemplate{
        \\
    );
    for (templates.items, 0..) |template_entry, index| {
        try writer.writeAll("    .{ .code = ");
        try writer.print("{d}", .{index + 1});
        try writer.writeAll(", .name = ");
        try appendZigStringLiteral(writer, template_entry.name);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const TargetLanguage = struct {
        \\    code: u16,
        \\    value: []const u8,
        \\};
        \\
        \\pub const target_languages = [_]TargetLanguage{
        \\
    );
    for (target_languages.items, 0..) |lang_entry, index| {
        try writer.writeAll("    .{ .code = ");
        try writer.print("{d}", .{index + 1});
        try writer.writeAll(", .value = ");
        try appendZigStringLiteral(writer, lang_entry.value);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const LanguageLabel = struct {
        \\    code: u16,
        \\    label: []const u8,
        \\};
        \\
        \\pub const language_labels = [_]LanguageLabel{
        \\
    );
    for (labels.items, 0..) |label_entry, index| {
        try writer.writeAll("    .{ .code = ");
        try writer.print("{d}", .{index + 1});
        try writer.writeAll(", .label = ");
        try appendZigStringLiteral(writer, label_entry.label);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll("};\n");

    return allocator.dupe(u8, out.written());
}

fn readFileAllocAbsolute(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const io = std.Options.debug_io;
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > max_bytes) return error.FileTooBig;

    const out = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(out);

    const read_len = try file.readPositionalAll(io, out, 0);
    if (read_len == out.len) return out;

    const shrunk = try allocator.dupe(u8, out[0..read_len]);
    allocator.free(out);
    return shrunk;
}

fn sectionKindNameForParser(parser_kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, parser_kind, "part-of-speech")) return "pos_lines";
    if (std.mem.eql(u8, parser_kind, "alternative-forms")) return "term_list";
    if (std.mem.eql(u8, parser_kind, "relations")) return "term_list";
    if (std.mem.eql(u8, parser_kind, "navigation")) return "term_list";
    if (std.mem.eql(u8, parser_kind, "translations")) return "translations";
    // These section families are structurally loose and often contain free-form
    // wikitext, comments, refs, or mixed templates that are not worth forcing
    // through the line-stream codec. Keep them as raw joined bodies.
    if (std.mem.eql(u8, parser_kind, "citations")) return "lines";
    if (std.mem.eql(u8, parser_kind, "descendants")) return "lines";
    if (std.mem.eql(u8, parser_kind, "etymology")) return "lines";
    if (std.mem.eql(u8, parser_kind, "inflection")) return "lines";
    if (std.mem.eql(u8, parser_kind, "language-root")) return "lines";
    if (std.mem.eql(u8, parser_kind, "meta")) return "lines";
    if (std.mem.eql(u8, parser_kind, "notes")) return "lines";
    if (std.mem.eql(u8, parser_kind, "pronunciation")) return "lines";
    return null;
}

fn isTranslationHeading(heading: []const u8) bool {
    return std.mem.eql(u8, heading, "Translations") or std.mem.eql(u8, heading, "Translate");
}

fn generatedHeadingLessThan(_: void, a: GeneratedHeading, b: GeneratedHeading) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.title, b.title);
}

fn generatedLabelLessThan(_: void, a: GeneratedLabel, b: GeneratedLabel) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.label, b.label);
}

fn generatedTemplateLessThan(_: void, a: GeneratedTemplate, b: GeneratedTemplate) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn generatedLineTemplateLessThan(_: void, a: GeneratedLineTemplate, b: GeneratedLineTemplate) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn generatedCompactPatternLessThan(_: void, a: GeneratedCompactPattern, b: GeneratedCompactPattern) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.pattern, b.pattern);
}

fn seedCoveredCompactPatterns(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    covered: *std.StringHashMapUnmanaged(void),
) !void {
    const source = try readFileAllocAbsolute(allocator, source_path, 512 * 1024);
    defer allocator.free(source);

    const marker = "pub const static_escaped_patterns = [_][]const u8{";
    const start = std.mem.indexOf(u8, source, marker) orelse return error.InvalidCompactEncodingSource;

    var cursor: usize = start + marker.len;
    while (cursor < source.len) {
        if (std.mem.startsWith(u8, source[cursor..], "};")) break;
        if (source[cursor] != '"') {
            cursor += 1;
            continue;
        }
        cursor += 1;

        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(allocator);

        while (cursor < source.len) {
            const byte = source[cursor];
            if (byte == '\\') {
                if (cursor + 1 >= source.len) return error.InvalidCompactEncodingSource;
                const escaped = source[cursor + 1];
                switch (escaped) {
                    'n' => try decoded.append(allocator, '\n'),
                    'r' => try decoded.append(allocator, '\r'),
                    't' => try decoded.append(allocator, '\t'),
                    '\\' => try decoded.append(allocator, '\\'),
                    '"' => try decoded.append(allocator, '"'),
                    else => try decoded.append(allocator, escaped),
                }
                cursor += 2;
                continue;
            }
            if (byte == '"') {
                cursor += 1;
                break;
            }
            try decoded.append(allocator, byte);
            cursor += 1;
        }

        if (!std.mem.startsWith(u8, decoded.items, "{{")) continue;
        const body = decoded.items[2..];
        var end: usize = 0;
        while (end < body.len and body[end] != '|' and body[end] != '}' and body[end] != '\n') : (end += 1) {}
        if (end == 0) continue;

        const name = body[0..end];
        const gop = try covered.getOrPut(allocator, name);
        if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, name);
    }
}

fn compactPatternForTemplate(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    if (std.mem.indexOfAny(u8, name, "\r\n")) |_| return null;

    if (std.mem.startsWith(u8, name, "en-") or
        std.mem.eql(u8, name, "enPR") or
        std.mem.eql(u8, name, "...") or
        std.mem.eql(u8, name, "nb..."))
    {
        return std.fmt.allocPrint(allocator, "{{{{{s}", .{name}) catch null;
    }

    return std.fmt.allocPrint(allocator, "{{{{{s}|", .{name}) catch null;
}

fn generatedTargetLanguageLessThan(_: void, a: GeneratedTargetLanguage, b: GeneratedTargetLanguage) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.value, b.value);
}

fn appendZigStringLiteral(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    for (bytes) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try writer.writeByte(byte),
            else => try writer.print("\\x{X:0>2}", .{byte}),
        }
    }
    try writer.writeByte('"');
}
