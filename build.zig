const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const structure_optimize: std.builtin.OptimizeMode = .ReleaseFast;
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

    const encoder_mod = b.addModule("encoder", .{
        .root_source_file = b.path("encoder/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    encoder_mod.addImport("zxml", zxml_dep.module("zxml"));
    encoder_mod.addImport("generated_structure_tables", generated_tables.regular);
    const encoder_mod_structure = b.addModule("encoder_structure", .{
        .root_source_file = b.path("encoder/root.zig"),
        .target = target,
        .optimize = structure_optimize,
    });
    encoder_mod_structure.addImport("zxml", zxml_dep_structure.module("zxml"));
    encoder_mod_structure.addImport("generated_structure_tables", generated_tables.structure);

    const decoder_mod = b.addModule("decoder", .{
        .root_source_file = b.path("decoder/root.zig"),
        .target = target,
        .optimize = optimize,
    });
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
    if (parsed.value.templates_by_heading) |template_rows| {
        for (template_rows) |entry| {
            if (!isTranslationHeading(entry.heading)) continue;
            const template_name = std.mem.trim(u8, entry.template, " \t\r\n");
            if (template_name.len == 0) continue;
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
        }
    }
    std.mem.sortUnstable(GeneratedTemplate, templates.items, {}, generatedTemplateLessThan);

    if (headings.items.len + 1 > std.math.maxInt(u16)) return error.TooManyGeneratedHeadings;
    if (templates.items.len > std.math.maxInt(u16)) return error.TooManyGeneratedTemplates;
    if (labels.items.len > std.math.maxInt(u16)) return error.TooManyGeneratedLabels;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll(
        \\// Generated by build.zig from data/wiktionary-structure.json.
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
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const amt = try std.posix.read(fd, &buf);
        if (amt == 0) break;
        if (out.items.len + amt > max_bytes) return error.FileTooBig;
        try out.appendSlice(allocator, buf[0..amt]);
    }
    return out.toOwnedSlice(allocator);
}

fn sectionKindNameForParser(parser_kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, parser_kind, "part-of-speech")) return "pos_lines";
    if (std.mem.eql(u8, parser_kind, "alternative-forms")) return "term_list";
    if (std.mem.eql(u8, parser_kind, "relations")) return "term_list";
    if (std.mem.eql(u8, parser_kind, "navigation")) return "term_list";
    if (std.mem.eql(u8, parser_kind, "translations")) return "translations";
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
