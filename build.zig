const std = @import("std");

pub fn build(b: *std.Build) void {
    b.graph.incremental = false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const codegen_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const structure_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const default_skip_headings = "anagrams,citations,meta,statistics,further_reading,translations";
    const skip_headings_csv = b.option([]const u8, "skip-headings", "Comma-separated headings or heading families to exclude, e.g. Anagrams,Translations") orelse default_skip_headings;
    const filter_languages_csv = b.option([]const u8, "language", "Language headings to store; defaults to English, use all for every language, or a comma-separated list such as English,Chinese") orelse "English";
    const config_options = b.addOptions();
    config_options.addOption([]const u8, "skip_headings_csv", skip_headings_csv);
    config_options.addOption([]const u8, "filter_languages_csv", filter_languages_csv);
    const zxml_config_path = addZxmlConfigModule(b);
    const bootstrap_generated_tables = addBootstrapStructureTableModules(b, target, optimize, structure_optimize);
    const structure_codegen_bin = addDirectStructureTablesCodegenBinary(b);
    const cli_args_mod = b.createModule(.{
        .root_source_file = b.path("tools/cli_args.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli_args_mod_codegen = b.createModule(.{
        .root_source_file = b.path("tools/cli_args.zig"),
        .target = target,
        .optimize = codegen_optimize,
    });
    const required_path_mod = b.createModule(.{
        .root_source_file = b.path("tools/required_path.zig"),
        .target = target,
        .optimize = optimize,
    });
    const required_path_mod_codegen = b.createModule(.{
        .root_source_file = b.path("tools/required_path.zig"),
        .target = target,
        .optimize = codegen_optimize,
    });
    const encoder_tool_paths_options = b.addOptions();
    const decoder_tool_paths_options = b.addOptions();
    const verifier_tool_paths_options = b.addOptions();
    const encoder_tool_paths_mod = encoder_tool_paths_options.createModule();
    const decoder_tool_paths_mod = decoder_tool_paths_options.createModule();
    const verifier_tool_paths_mod = verifier_tool_paths_options.createModule();
    const cli_args_mod_structure = b.createModule(.{
        .root_source_file = b.path("tools/cli_args.zig"),
        .target = target,
        .optimize = structure_optimize,
    });

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
    const normalize_mod_codegen = b.createModule(.{
        .root_source_file = b.path("decoder/normalize.zig"),
        .target = target,
        .optimize = codegen_optimize,
    });
    const normalize_mod_structure = b.createModule(.{
        .root_source_file = b.path("decoder/normalize.zig"),
        .target = target,
        .optimize = structure_optimize,
    });
    const shared_html_entities_mod = b.createModule(.{
        .root_source_file = b.path("shared/html_entities.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_xml_decode_mod = b.createModule(.{
        .root_source_file = b.path("shared/xml_decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_xml_decode_mod_codegen = b.createModule(.{
        .root_source_file = b.path("shared/xml_decode.zig"),
        .target = target,
        .optimize = codegen_optimize,
    });
    const shared_structure_report_mod = b.createModule(.{
        .root_source_file = b.path("shared/structure_report.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_structure_report_mod_codegen = b.createModule(.{
        .root_source_file = b.path("shared/structure_report.zig"),
        .target = target,
        .optimize = codegen_optimize,
    });
    const lua_mod = b.addModule("lua", .{
        .root_source_file = b.path("lua/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lua_mod.addImport("shared_xml_decode", shared_xml_decode_mod);
    const lua_mod_codegen = b.createModule(.{
        .root_source_file = b.path("lua/root.zig"),
        .target = target,
        .optimize = codegen_optimize,
    });
    lua_mod_codegen.addImport("shared_xml_decode", shared_xml_decode_mod_codegen);
    const compact_pattern_seed_mod = b.createModule(.{
        .root_source_file = b.path("shared/compact_pattern_seed.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compact_pattern_seed_mod_codegen = b.createModule(.{
        .root_source_file = b.path("shared/compact_pattern_seed.zig"),
        .target = target,
        .optimize = codegen_optimize,
    });
    const wikitext_source_mod = b.createModule(.{
        .root_source_file = b.path("encoder/wikitext.zig"),
        .target = target,
        .optimize = optimize,
    });
    wikitext_source_mod.addOptions("config", config_options);
    wikitext_source_mod.addImport("shared_xml_decode", shared_xml_decode_mod);
    const wikitext_source_mod_codegen = b.createModule(.{
        .root_source_file = b.path("encoder/wikitext.zig"),
        .target = target,
        .optimize = codegen_optimize,
    });
    wikitext_source_mod_codegen.addOptions("config", config_options);
    wikitext_source_mod_codegen.addImport("shared_xml_decode", shared_xml_decode_mod_codegen);
    const template_compiler_support_mod = b.createModule(.{
        .root_source_file = b.path("renderer/template_compiler_support.zig"),
        .target = target,
        .optimize = optimize,
    });
    template_compiler_support_mod.addImport("lua", lua_mod);
    const generated_template_runtime_mod = addGeneratedTemplateRuntimeModule(
        b,
        target,
        optimize,
        lua_mod,
        template_compiler_support_mod,
    );
    const renderer_mod = b.addModule("renderer", .{
        .root_source_file = b.path("renderer/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    renderer_mod.addImport("shared_html_entities", shared_html_entities_mod);
    renderer_mod.addImport("shared_xml_decode", shared_xml_decode_mod);
    renderer_mod.addImport("lua", lua_mod);
    renderer_mod.addImport("template_compiler_support", template_compiler_support_mod);
    renderer_mod.addImport("generated_template_runtime", generated_template_runtime_mod);
    const encoder_mod_bootstrap = b.addModule("encoder_bootstrap", .{
        .root_source_file = b.path("encoder/root.zig"),
        .target = target,
        .optimize = structure_optimize,
    });
    encoder_mod_bootstrap.addOptions("config", config_options);
    encoder_mod_bootstrap.addImport("normalize", normalize_mod_structure);
    encoder_mod_bootstrap.addImport("zxml", zxml_dep_structure.module("zxml"));
    encoder_mod_bootstrap.addImport("generated_structure_tables", bootstrap_generated_tables.structure);
    encoder_mod_bootstrap.addImport("cli_args", cli_args_mod_structure);
    encoder_mod_bootstrap.addImport("shared_html_entities", shared_html_entities_mod);
    encoder_mod_bootstrap.addImport("shared_xml_decode", shared_xml_decode_mod);
    encoder_mod_bootstrap.addImport("shared_structure_report", shared_structure_report_mod);
    encoder_mod_bootstrap.addImport("compact_pattern_seed", compact_pattern_seed_mod);
    encoder_mod_bootstrap.addImport("wikitext_source", wikitext_source_mod);

    const structure_bin = addDirectStructureBinary(
        b,
        config_options.getOutput(),
        zxml_config_path,
        bootstrap_generated_tables.structure_source,
    );
    const generated_tables = if (existingBuildPath(b, "data/wiktionary-structure.json")) |existing_structure_report|
        addGeneratedStructureTableModules(
            b,
            target,
            optimize,
            structure_optimize,
            structure_codegen_bin,
            existing_structure_report,
        )
    else
        bootstrap_generated_tables;
    const verifier_bin = addDirectVerifierBinary(
        b,
        config_options.getOutput(),
        zxml_config_path,
        generated_tables.regular_source,
        verifier_tool_paths_options.getOutput(),
    );
    const encoder_mod = b.addModule("encoder", .{
        .root_source_file = b.path("encoder/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    encoder_mod.addOptions("config", config_options);
    encoder_mod.addImport("normalize", normalize_mod);
    encoder_mod.addImport("zxml", zxml_dep.module("zxml"));
    encoder_mod.addImport("generated_structure_tables", generated_tables.regular);
    encoder_mod.addImport("cli_args", cli_args_mod);
    encoder_mod.addImport("shared_html_entities", shared_html_entities_mod);
    encoder_mod.addImport("shared_xml_decode", shared_xml_decode_mod);
    encoder_mod.addImport("shared_structure_report", shared_structure_report_mod);
    encoder_mod.addImport("compact_pattern_seed", compact_pattern_seed_mod);
    encoder_mod.addImport("wikitext_source", wikitext_source_mod);

    const encoder_mod_test = b.addModule("encoder_test", .{
        .root_source_file = b.path("encoder/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    encoder_mod_test.addOptions("config", config_options);
    encoder_mod_test.addImport("normalize", normalize_mod);
    encoder_mod_test.addImport("zxml", zxml_dep.module("zxml"));
    encoder_mod_test.addImport("generated_structure_tables", bootstrap_generated_tables.regular);
    encoder_mod_test.addImport("cli_args", cli_args_mod);
    encoder_mod_test.addImport("shared_html_entities", shared_html_entities_mod);
    encoder_mod_test.addImport("shared_xml_decode", shared_xml_decode_mod);
    encoder_mod_test.addImport("shared_structure_report", shared_structure_report_mod);
    encoder_mod_test.addImport("compact_pattern_seed", compact_pattern_seed_mod);
    encoder_mod_test.addImport("wikitext_source", wikitext_source_mod);

    const decoder_mod = b.addModule("decoder", .{
        .root_source_file = b.path("decoder/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    decoder_mod.addOptions("config", config_options);
    decoder_mod.addImport("normalize", normalize_mod);
    decoder_mod.addImport("shared_xml_decode", shared_xml_decode_mod);
    decoder_mod.addImport("shared_structure_report", shared_structure_report_mod);
    decoder_mod.addImport("wikitext_source", wikitext_source_mod);
    decoder_mod.addImport("cli_args", cli_args_mod);
    const decoder_mod_codegen = b.createModule(.{
        .root_source_file = b.path("decoder/root.zig"),
        .target = target,
        .optimize = codegen_optimize,
    });
    decoder_mod_codegen.addOptions("config", config_options);
    decoder_mod_codegen.addImport("normalize", normalize_mod_codegen);
    decoder_mod_codegen.addImport("shared_xml_decode", shared_xml_decode_mod_codegen);
    decoder_mod_codegen.addImport("shared_structure_report", shared_structure_report_mod_codegen);
    decoder_mod_codegen.addImport("wikitext_source", wikitext_source_mod_codegen);
    decoder_mod_codegen.addImport("cli_args", cli_args_mod_codegen);

    const decoder_mod_test = b.addModule("decoder_test", .{
        .root_source_file = b.path("decoder/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    decoder_mod_test.addOptions("config", config_options);
    decoder_mod_test.addImport("normalize", normalize_mod);
    decoder_mod_test.addImport("encoder", encoder_mod_test);
    decoder_mod_test.addImport("shared_xml_decode", shared_xml_decode_mod);
    decoder_mod_test.addImport("shared_structure_report", shared_structure_report_mod);
    decoder_mod_test.addImport("wikitext_source", wikitext_source_mod);
    decoder_mod_test.addImport("cli_args", cli_args_mod);

    const backend_mod = b.addModule("backend", .{
        .root_source_file = b.path("backend/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend_mod.addImport("decoder", decoder_mod);
    backend_mod.addImport("zhttp", zhttp_dep.module("zhttp"));
    backend_mod.addImport("cli_args", cli_args_mod);
    backend_mod.addImport("shared_html_entities", shared_html_entities_mod);
    backend_mod.addImport("renderer", renderer_mod);

    const backend_mod_test = b.addModule("backend_test", .{
        .root_source_file = b.path("backend/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend_mod_test.addImport("decoder", decoder_mod_test);
    backend_mod_test.addImport("zhttp", zhttp_dep.module("zhttp"));
    backend_mod_test.addImport("cli_args", cli_args_mod);
    backend_mod_test.addImport("shared_html_entities", shared_html_entities_mod);
    backend_mod_test.addImport("renderer", renderer_mod);

    const encoder_exe = addCliExecutable(b, "dict-encoder", b.path("encoder/main.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = encoder_mod },
        .{ .name = "cli_args", .module = cli_args_mod },
        .{ .name = "required_path", .module = required_path_mod },
        .{ .name = "tool_paths", .module = encoder_tool_paths_mod },
    });
    const decoder_exe = addCliExecutable(b, "dict-decoder", b.path("decoder/main.zig"), target, optimize, &.{
        .{ .name = "decoder", .module = decoder_mod },
        .{ .name = "cli_args", .module = cli_args_mod },
        .{ .name = "required_path", .module = required_path_mod },
        .{ .name = "tool_paths", .module = decoder_tool_paths_mod },
    });
    const backend_exe = addCliExecutable(b, "dict-backend", b.path("backend/main.zig"), target, optimize, &.{
        .{ .name = "backend", .module = backend_mod },
        .{ .name = "cli_args", .module = cli_args_mod },
    });
    const verifier_exe = addCliExecutable(b, "dict-verify", b.path("tools/verifier.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = encoder_mod },
        .{ .name = "decoder", .module = decoder_mod },
        .{ .name = "zxml", .module = zxml_dep.module("zxml") },
        .{ .name = "tool_paths", .module = verifier_tool_paths_mod },
    });
    const template_audit_exe = addCliExecutable(b, "dict-template-audit", b.path("tools/template_audit.zig"), target, optimize, &.{
        .{ .name = "renderer", .module = renderer_mod },
        .{ .name = "wikitext_source", .module = wikitext_source_mod },
        .{ .name = "cli_args", .module = cli_args_mod },
        .{ .name = "required_path", .module = required_path_mod },
    });
    const template_codegen_exe = addCliExecutable(b, "dict-template-compile", b.path("tools/template_codegen.zig"), target, codegen_optimize, &.{
        .{ .name = "lua", .module = lua_mod_codegen },
        .{ .name = "required_path", .module = required_path_mod_codegen },
        .{ .name = "shared_structure_report", .module = shared_structure_report_mod_codegen },
    });
    const frontend_exe = addCliExecutable(b, "dict-frontend", b.path("tools/frontend.zig"), target, optimize, &.{});
    const lua_exe = addCliExecutable(b, "dict-lua", b.path("tools/lua_translate.zig"), target, codegen_optimize, &.{
        .{ .name = "lua", .module = lua_mod_codegen },
        .{ .name = "decoder", .module = decoder_mod_codegen },
        .{ .name = "compact_pattern_seed", .module = compact_pattern_seed_mod_codegen },
        .{ .name = "required_path", .module = required_path_mod_codegen },
        .{ .name = "shared_structure_report", .module = shared_structure_report_mod_codegen },
    });
    encoder_tool_paths_options.addOptionPath("structure_bin_path", structure_bin);
    decoder_tool_paths_options.addOptionPath("encoder_bin_path", encoder_exe.getEmittedBin());
    verifier_tool_paths_options.addOptionPath("decoder_bin_path", decoder_exe.getEmittedBin());

    const structure_install = b.addInstallBinFile(structure_bin, "dict-structure");
    const encoder_install = b.addInstallArtifact(encoder_exe, .{});
    const decoder_install = b.addInstallArtifact(decoder_exe, .{});
    const backend_install = b.addInstallArtifact(backend_exe, .{});
    const verifier_install = b.addInstallArtifact(verifier_exe, .{});
    const template_audit_install = b.addInstallArtifact(template_audit_exe, .{});
    const template_codegen_install = b.addInstallArtifact(template_codegen_exe, .{});
    const frontend_install = b.addInstallArtifact(frontend_exe, .{});
    const lua_install = b.addInstallArtifact(lua_exe, .{});
    b.getInstallStep().dependOn(&structure_install.step);
    b.getInstallStep().dependOn(&encoder_install.step);
    b.getInstallStep().dependOn(&decoder_install.step);
    b.getInstallStep().dependOn(&backend_install.step);
    b.getInstallStep().dependOn(&verifier_install.step);
    b.getInstallStep().dependOn(&template_audit_install.step);
    b.getInstallStep().dependOn(&template_codegen_install.step);
    b.getInstallStep().dependOn(&frontend_install.step);
    b.getInstallStep().dependOn(&lua_install.step);

    const structure_run = addDirectToolRunCommand(b, structure_bin, &.{}, b.args);
    addPublicRunStep(b, "structure", "Analyze Wiktionary structure", structure_run, &.{});

    const encode_run = addRunArtifactCommand(b, encoder_exe, &.{}, b.args);
    addPublicRunStep(b, "encode", "Run the encoder CLI", encode_run, &.{structure_bin.generated.file.step});

    const decode_run = addRunArtifactCommand(b, decoder_exe, &.{}, b.args);
    addPublicRunStep(b, "decode", "Run the decoder CLI", decode_run, &.{ structure_bin.generated.file.step, &encoder_exe.step });

    const serve_run = addRunArtifactCommand(b, backend_exe, &.{}, b.args);
    addPublicRunStep(b, "serve", "Run the backend server", serve_run, &.{});

    const verify_run = addDirectToolRunCommand(b, verifier_bin, &.{}, b.args);
    addPublicRunStep(b, "verify", "Verify dictionary raw entries against the XML dump", verify_run, &.{ structure_bin.generated.file.step, &encoder_exe.step, &decoder_exe.step });

    const template_audit_run = addRunArtifactCommand(b, template_audit_exe, &.{}, b.args);
    addPublicRunStep(b, "template-audit", "Audit every structure-listed template against renderer output", template_audit_run, &.{});

    const template_codegen_run = addRunArtifactCommand(b, template_codegen_exe, &.{}, b.args);
    addPublicRunStep(b, "template-compile", "Compile reachable template pages into generated Zig runtime code", template_codegen_run, &.{});

    const frontend_run = addRunArtifactCommand(b, frontend_exe, &.{}, b.args);
    addPublicRunStep(b, "frontend", "Run the frontend CLI", frontend_run, &.{});

    const lua_run = addRunArtifactCommand(b, lua_exe, &.{}, b.args);
    addPublicRunStep(b, "lua", "Run the Lua translator CLI", lua_run, &.{});

    const test_runner = b.path("tools/test_runner.zig");

    const encoder_tests = b.addTest(.{
        .root_module = encoder_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const decoder_tests = b.addTest(.{
        .root_module = decoder_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const backend_tests = b.addTest(.{
        .root_module = backend_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const renderer_tests = b.addTest(.{
        .root_module = renderer_mod,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const structure_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/structure_analyzer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "encoder", .module = encoder_mod_test },
                .{ .name = "lua", .module = lua_mod },
                .{ .name = "zxml", .module = zxml_dep.module("zxml") },
                .{ .name = "compact_pattern_seed", .module = compact_pattern_seed_mod },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const structure_tables_support_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/structure_tables_support.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compact_pattern_seed", .module = compact_pattern_seed_mod },
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
                .{ .name = "encoder", .module = encoder_mod_test },
                .{ .name = "decoder", .module = decoder_mod_test },
                .{ .name = "zxml", .module = zxml_dep.module("zxml") },
                .{ .name = "tool_paths", .module = verifier_tool_paths_mod },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const template_audit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/template_audit.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "renderer", .module = renderer_mod },
                .{ .name = "wikitext_source", .module = wikitext_source_mod },
                .{ .name = "cli_args", .module = cli_args_mod },
                .{ .name = "required_path", .module = required_path_mod },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const lua_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lua/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared_xml_decode", .module = shared_xml_decode_mod },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const template_codegen_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/template_codegen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lua", .module = lua_mod },
                .{ .name = "required_path", .module = required_path_mod },
                .{ .name = "shared_structure_report", .module = shared_structure_report_mod },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const run_encoder_tests = b.addRunArtifact(encoder_tests);
    const run_decoder_tests = b.addRunArtifact(decoder_tests);
    const run_backend_tests = b.addRunArtifact(backend_tests);
    const run_renderer_tests = b.addRunArtifact(renderer_tests);
    const run_structure_tests = b.addRunArtifact(structure_tests);
    const run_structure_tables_support_tests = b.addRunArtifact(structure_tables_support_tests);
    const run_verifier_tests = b.addRunArtifact(verifier_tests);
    const run_template_audit_tests = b.addRunArtifact(template_audit_tests);
    const run_lua_tests = b.addRunArtifact(lua_tests);
    const run_template_codegen_tests = b.addRunArtifact(template_codegen_tests);

    const test_step = b.step("test", "Run encoder, decoder, and backend tests");
    test_step.dependOn(&run_encoder_tests.step);
    test_step.dependOn(&run_decoder_tests.step);
    test_step.dependOn(&run_backend_tests.step);
    test_step.dependOn(&run_renderer_tests.step);
    test_step.dependOn(&run_structure_tests.step);
    test_step.dependOn(&run_structure_tables_support_tests.step);
    test_step.dependOn(&run_verifier_tests.step);
    test_step.dependOn(&run_template_audit_tests.step);
    test_step.dependOn(&run_lua_tests.step);
    test_step.dependOn(&run_template_codegen_tests.step);
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

fn addRunArtifactCommand(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    fixed_args: []const []const u8,
    passthrough_args: ?[]const []const u8,
) *std.Build.Step.Run {
    const run_cmd = b.addRunArtifact(exe);
    for (fixed_args) |arg| run_cmd.addArg(arg);
    if (passthrough_args) |args| run_cmd.addArgs(args);
    return run_cmd;
}

fn addDirectToolRunCommand(
    b: *std.Build,
    binary_path: std.Build.LazyPath,
    fixed_args: []const []const u8,
    passthrough_args: ?[]const []const u8,
) *std.Build.Step.Run {
    const run_cmd = b.addSystemCommand(&.{"/usr/bin/env"});
    run_cmd.addFileArg(binary_path);
    for (fixed_args) |arg| run_cmd.addArg(arg);
    if (passthrough_args) |args| run_cmd.addArgs(args);
    return run_cmd;
}

fn addPublicRunStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    run_cmd: *std.Build.Step.Run,
    deps: []const *std.Build.Step,
) void {
    const step = b.step(name, description);
    for (deps) |dep| step.dependOn(dep);
    step.dependOn(&run_cmd.step);
}

fn existingBuildPath(b: *std.Build, relative_path: []const u8) ?std.Build.LazyPath {
    _ = std.Io.Dir.cwd().statFile(b.graph.io, relative_path, .{}) catch return null;
    return b.path(relative_path);
}

fn addGeneratedTemplateRuntimeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lua_mod: *std.Build.Module,
    template_compiler_support_mod: *std.Build.Module,
) *std.Build.Module {
    const source = loadGeneratedTemplateRuntimeSourceAlloc(b) catch |err| {
        std.debug.panic("failed to prepare generated template runtime: {s}", .{@errorName(err)});
    };
    const write_files = b.addWriteFiles();
    const generated_path = write_files.add("generated/template_runtime.zig", source);
    const generated_mod = b.createModule(.{
        .root_source_file = generated_path,
        .target = target,
        .optimize = optimize,
    });
    generated_mod.addImport("lua", lua_mod);
    generated_mod.addImport("template_compiler_support", template_compiler_support_mod);
    return generated_mod;
}

fn loadGeneratedTemplateRuntimeSourceAlloc(b: *std.Build) ![]const u8 {
    const source = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        b.pathFromRoot("data/generated_template_runtime.zig"),
        b.allocator,
        std.Io.Limit.limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return b.allocator.dupe(u8, generatedTemplateRuntimeStubSource),
        else => return err,
    };
    return rewriteTemplateRuntimeImportsAlloc(b.allocator, source);
}

fn rewriteTemplateRuntimeImportsAlloc(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var start: usize = 0;
    while (std.mem.indexOfPos(u8, source, start, "template_compiler_support.zig")) |idx| {
        try out.appendSlice(allocator, source[start..idx]);
        try out.appendSlice(allocator, "template_compiler_support");
        start = idx + "template_compiler_support.zig".len;
    }
    try out.appendSlice(allocator, source[start..]);
    return out.toOwnedSlice(allocator);
}

const generatedTemplateRuntimeStubSource =
    \\const std = @import("std");
    \\const support = @import("template_compiler_support");
    \\
    \\pub const TemplateClass = support.TemplateClass;
    \\// Compact index used by the generated template switch dispatcher.
    \\pub const TemplateRenderIndex = u16;
    \\// Shared lookup shape used by the renderers when the generated runtime is absent.
    \\pub const TemplateLookup = struct {
    \\    class: TemplateClass,
    \\    render_index: TemplateRenderIndex,
    \\};
    \\
    \\pub fn classifyTemplate(name: []const u8) ?TemplateClass {
    \\    const lookup = lookupTemplate(name) orelse return null;
    \\    return lookup.class;
    \\}
    \\
    \\pub fn lookupTemplate(name: []const u8) ?TemplateLookup {
    \\    if (name.len == 0) return null;
    \\    return .{ .class = .unsupported, .render_index = 0 };
    \\}
    \\
    \\pub fn renderTemplateByIndex(
    \\    out: *std.ArrayList(u8),
    \\    allocator: std.mem.Allocator,
    \\    render_index: TemplateRenderIndex,
    \\    args: *const support.TemplateArgs,
    \\) !bool {
    \\    _ = out;
    \\    _ = allocator;
    \\    _ = render_index;
    \\    _ = args;
    \\    return false;
    \\}
    \\
;

const GeneratedStructureModules = struct {
    regular: *std.Build.Module,
    structure: *std.Build.Module,
    regular_source: std.Build.LazyPath,
    structure_source: std.Build.LazyPath,
};

const StructureReport = struct {
    heading_profiles: []const HeadingProfile,
    headings_by_level: ?[]const CountEntry = null,
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

const GeneratedHeadingLevel = struct {
    title: []const u8,
    level: u8,
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

fn addBootstrapStructureTableModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    structure_optimize: std.builtin.OptimizeMode,
) GeneratedStructureModules {
    const generated_source = generateDefaultStructureTableSource(b) catch |err| {
        std.debug.panic("failed to generate bootstrap structure tables: {s}", .{@errorName(err)});
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
        .regular_source = generated_path,
        .structure_source = generated_path,
    };
}

fn addGeneratedStructureTableModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    structure_optimize: std.builtin.OptimizeMode,
    codegen_bin: std.Build.LazyPath,
    json_path: std.Build.LazyPath,
) GeneratedStructureModules {
    const codegen_run = b.addSystemCommand(&.{"/usr/bin/env"});
    codegen_run.addFileArg(codegen_bin);
    codegen_run.addArg("--input");
    codegen_run.addFileArg(json_path);
    codegen_run.addArg("--output");
    const generated_source = codegen_run.addOutputFileArg("structure_tables.zig");
    codegen_run.expectExitCode(0);
    _ = codegen_run.captureStdErr(.{ .basename = "structure_tables_codegen.stderr" });

    return .{
        .regular = b.createModule(.{
            .root_source_file = generated_source,
            .target = target,
            .optimize = optimize,
        }),
        .structure = b.createModule(.{
            .root_source_file = generated_source,
            .target = target,
            .optimize = structure_optimize,
        }),
        .regular_source = generated_source,
        .structure_source = generated_source,
    };
}

fn addDirectStructureTablesCodegenBinary(b: *std.Build) std.Build.LazyPath {
    const compile = b.addSystemCommand(&.{ b.graph.zig_exe, "build-exe", "-OReleaseFast" });
    compile.addArgs(&.{ "--dep", "compact_pattern_seed" });
    compile.addPrefixedFileArg("-Mroot=", b.path("tools/structure_tables_codegen.zig"));
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mcompact_pattern_seed=", b.path("shared/compact_pattern_seed.zig"));
    const output = compile.addPrefixedOutputFileArg("-femit-bin=", "dict-structure-tables-codegen");
    return output;
}

fn addDirectStructureBinary(
    b: *std.Build,
    config_path: std.Build.LazyPath,
    config0_path: std.Build.LazyPath,
    bootstrap_tables_path: std.Build.LazyPath,
) std.Build.LazyPath {
    const compile = b.addSystemCommand(&.{ b.graph.zig_exe, "build-exe", "-OReleaseFast" });
    compile.addArgs(&.{ "--dep", "encoder", "--dep", "lua", "--dep", "zxml", "--dep", "compact_pattern_seed", "--dep", "wikitext_source" });
    compile.addPrefixedFileArg("-Mroot=", b.path("tools/structure_analyzer.zig"));
    compile.addArg("-OReleaseFast");
    compile.addArgs(&.{
        "--dep",
        "config",
        "--dep",
        "normalize",
        "--dep",
        "zxml",
        "--dep",
        "generated_structure_tables",
        "--dep",
        "cli_args",
        "--dep",
        "shared_html_entities",
        "--dep",
        "shared_xml_decode",
        "--dep",
        "shared_structure_report",
        "--dep",
        "compact_pattern_seed",
        "--dep",
        "wikitext_source",
    });
    compile.addPrefixedFileArg("-Mencoder=", b.path("encoder/root.zig"));
    compile.addArg("-OReleaseFast");
    compile.addArgs(&.{ "--dep", "shared_xml_decode" });
    compile.addPrefixedFileArg("-Mlua=", b.path("lua/root.zig"));
    compile.addArg("-OReleaseFast");
    compile.addArgs(&.{ "--dep", "shared_xml_decode" });
    compile.addArgs(&.{ "--dep", "config=config0" });
    compile.addPrefixedFileArg("-Mzxml=", b.path(".deps/zxml/src/root.zig"));
    compile.addPrefixedFileArg("-Mconfig=", config_path);
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mnormalize=", b.path("decoder/normalize.zig"));
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mgenerated_structure_tables=", bootstrap_tables_path);
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mcli_args=", b.path("tools/cli_args.zig"));
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mshared_html_entities=", b.path("shared/html_entities.zig"));
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mshared_xml_decode=", b.path("shared/xml_decode.zig"));
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mshared_structure_report=", b.path("shared/structure_report.zig"));
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mcompact_pattern_seed=", b.path("shared/compact_pattern_seed.zig"));
    compile.addArg("-OReleaseFast");
    compile.addArgs(&.{ "--dep", "config=config1", "--dep", "shared_xml_decode" });
    compile.addPrefixedFileArg("-Mwikitext_source=", b.path("encoder/wikitext.zig"));
    compile.addPrefixedFileArg("-Mconfig1=", config_path);
    compile.addPrefixedFileArg("-Mconfig0=", config0_path);
    return compile.addPrefixedOutputFileArg("-femit-bin=", "dict-structure");
}

fn addDirectVerifierBinary(
    b: *std.Build,
    config_path: std.Build.LazyPath,
    config0_path: std.Build.LazyPath,
    regular_tables_path: std.Build.LazyPath,
    tool_paths_path: std.Build.LazyPath,
) std.Build.LazyPath {
    const compile = b.addSystemCommand(&.{ b.graph.zig_exe, "build-exe", "-OReleaseFast" });
    compile.addArgs(&.{ "--dep", "encoder", "--dep", "decoder", "--dep", "zxml", "--dep", "compact_pattern_seed", "--dep", "tool_paths", "--dep", "wikitext_source" });
    compile.addPrefixedFileArg("-Mroot=", b.path("tools/verifier.zig"));
    compile.addArg("-OReleaseFast");
    compile.addArgs(&.{
        "--dep",
        "config",
        "--dep",
        "normalize",
        "--dep",
        "zxml",
        "--dep",
        "generated_structure_tables",
        "--dep",
        "cli_args",
        "--dep",
        "shared_html_entities",
        "--dep",
        "shared_xml_decode",
        "--dep",
        "shared_structure_report",
        "--dep",
        "compact_pattern_seed",
        "--dep",
        "wikitext_source",
    });
    compile.addPrefixedFileArg("-Mencoder=", b.path("encoder/root.zig"));
    compile.addArg("-OReleaseFast");
    compile.addArgs(&.{ "--dep", "normalize", "--dep", "encoder", "--dep", "shared_xml_decode", "--dep", "shared_structure_report", "--dep", "wikitext_source", "--dep", "cli_args", "--dep", "config=config1" });
    compile.addPrefixedFileArg("-Mdecoder=", b.path("decoder/root.zig"));
    compile.addArg("-OReleaseFast");
    compile.addArgs(&.{ "--dep", "config=config0" });
    compile.addPrefixedFileArg("-Mzxml=", b.path(".deps/zxml/src/root.zig"));
    compile.addPrefixedFileArg("-Mconfig=", config_path);
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mnormalize=", b.path("decoder/normalize.zig"));
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mgenerated_structure_tables=", regular_tables_path);
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mcli_args=", b.path("tools/cli_args.zig"));
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mshared_html_entities=", b.path("shared/html_entities.zig"));
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mshared_xml_decode=", b.path("shared/xml_decode.zig"));
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mshared_structure_report=", b.path("shared/structure_report.zig"));
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mcompact_pattern_seed=", b.path("shared/compact_pattern_seed.zig"));
    compile.addArg("-OReleaseFast");
    compile.addArgs(&.{ "--dep", "config=config1", "--dep", "shared_xml_decode" });
    compile.addPrefixedFileArg("-Mwikitext_source=", b.path("encoder/wikitext.zig"));
    compile.addPrefixedFileArg("-Mconfig1=", config_path);
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mtool_paths=", tool_paths_path);
    compile.addPrefixedFileArg("-Mconfig0=", config0_path);
    return compile.addPrefixedOutputFileArg("-femit-bin=", "dict-verify");
}

fn addZxmlConfigModule(b: *std.Build) std.Build.LazyPath {
    const write_files = b.addWriteFiles();
    return write_files.add("generated/zxml_config.zig",
        \\pub const intlen: enum { u16, u32, u64, usize } = .u32;
        \\
    );
}

fn generateDefaultStructureTableSource(b: *std.Build) ![]const u8 {
    return generateStructureTableSourceFromJson(
        b.allocator,
        default_structure_report_json,
    );
}

fn generateStructureTableSourceFromJson(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
) ![]const u8 {
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

    var heading_levels: std.ArrayList(GeneratedHeadingLevel) = .empty;
    defer heading_levels.deinit(allocator);
    if (parsed.value.headings_by_level) |heading_rows| {
        for (heading_rows) |entry| {
            const parsed_key = parseHeadingLevelKey(entry.key) orelse continue;
            if (std.mem.eql(u8, parsed_key.title, "English")) continue;
            const kind_name = headingKindNameForTitle(parsed.value.heading_profiles, parsed_key.title) orelse return error.InvalidStructureReport;
            try heading_levels.append(allocator, .{
                .title = try allocator.dupe(u8, parsed_key.title),
                .level = parsed_key.level,
                .kind_name = kind_name,
                .count = entry.count,
            });
        }
    }
    std.mem.sortUnstable(GeneratedHeadingLevel, heading_levels.items, {}, generatedHeadingLevelLessThan);

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
    if (heading_levels.items.len + 1 > std.math.maxInt(u16)) return error.TooManyGeneratedHeadingLevels;
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
        \\pub const HeadingLevelSpec = struct {
        \\    code: u16,
        \\    level: u8,
        \\    title: []const u8,
        \\    kind: SectionKind,
        \\};
        \\
        \\pub const heading_level_specs = [_]HeadingLevelSpec{
        \\
    );

    for (heading_levels.items, 0..) |heading, index| {
        try writer.writeAll("    .{ .code = ");
        try writer.print("{d}", .{index + 2});
        try writer.writeAll(", .level = ");
        try writer.print("{d}", .{heading.level});
        try writer.writeAll(", .title = ");
        try appendZigStringLiteral(writer, heading.title);
        try writer.writeAll(", .kind = .");
        try writer.writeAll(heading.kind_name);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll(
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
    try writer.writeAll(
        \\};
        \\
        \\fn fingerprintUpdateString(hasher: *std.hash.Wyhash, value: []const u8) void {
        \\    var len_buf: [8]u8 = undefined;
        \\    std.mem.writeInt(u64, &len_buf, value.len, .little);
        \\    hasher.update(&len_buf);
        \\    hasher.update(value);
        \\}
        \\
        \\pub const structure_fingerprint: u32 = blk: {
        \\    @setEvalBranchQuota(1_000_000);
        \\    var hasher = std.hash.Wyhash.init(0x8f3c2d17c4a9b651);
        \\
        \\    for (heading_level_specs) |entry| {
        \\        var code_buf: [2]u8 = undefined;
        \\        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        \\        hasher.update(&code_buf);
        \\        hasher.update(&[_]u8{entry.level});
        \\        fingerprintUpdateString(&hasher, entry.title);
        \\        hasher.update(&[_]u8{@intFromEnum(entry.kind)});
        \\    }
        \\    for (heading_specs) |entry| {
        \\        var code_buf: [2]u8 = undefined;
        \\        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        \\        hasher.update(&code_buf);
        \\        fingerprintUpdateString(&hasher, entry.title);
        \\        hasher.update(&[_]u8{@intFromEnum(entry.kind)});
        \\    }
        \\    for (line_templates) |entry| {
        \\        var code_buf: [2]u8 = undefined;
        \\        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        \\        hasher.update(&code_buf);
        \\        fingerprintUpdateString(&hasher, entry.name);
        \\    }
        \\    for (compact_patterns) |entry| {
        \\        fingerprintUpdateString(&hasher, entry);
        \\    }
        \\    for (compact_patterns_ext) |entry| {
        \\        fingerprintUpdateString(&hasher, entry);
        \\    }
        \\    for (translation_templates) |entry| {
        \\        var code_buf: [2]u8 = undefined;
        \\        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        \\        hasher.update(&code_buf);
        \\        fingerprintUpdateString(&hasher, entry.name);
        \\    }
        \\    for (target_languages) |entry| {
        \\        var code_buf: [2]u8 = undefined;
        \\        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        \\        hasher.update(&code_buf);
        \\        fingerprintUpdateString(&hasher, entry.value);
        \\    }
        \\    for (language_labels) |entry| {
        \\        var code_buf: [2]u8 = undefined;
        \\        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        \\        hasher.update(&code_buf);
        \\        fingerprintUpdateString(&hasher, entry.label);
        \\    }
        \\
        \\    break :blk @as(u32, @truncate(hasher.final()));
        \\};
        \\
    );

    return allocator.dupe(u8, out.written());
}

const default_structure_report_json =
    \\{
    \\  "heading_profiles": [
    \\    { "title": "English", "parser_kind": "language-root", "count": 1 },
    \\    { "title": "Noun", "parser_kind": "part-of-speech", "count": 1 },
    \\    { "title": "Verb", "parser_kind": "part-of-speech", "count": 1 },
    \\    { "title": "Adjective", "parser_kind": "part-of-speech", "count": 1 },
    \\    { "title": "Proper noun", "parser_kind": "part-of-speech", "count": 1 },
    \\    { "title": "Etymology", "parser_kind": "etymology", "count": 1 },
    \\    { "title": "Pronunciation", "parser_kind": "pronunciation", "count": 1 },
    \\    { "title": "Alternative forms", "parser_kind": "alternative-forms", "count": 1 },
    \\    { "title": "Translations", "parser_kind": "translations", "count": 1 },
    \\    { "title": "Derived terms", "parser_kind": "relations", "count": 1 },
    \\    { "title": "Synonyms", "parser_kind": "relations", "count": 1 },
    \\    { "title": "Usage notes", "parser_kind": "notes", "count": 1 },
    \\    { "title": "Conjugation", "parser_kind": "inflection", "count": 1 },
    \\    { "title": "Descendants", "parser_kind": "descendants", "count": 1 },
    \\    { "title": "See also", "parser_kind": "navigation", "count": 1 },
    \\    { "title": "References", "parser_kind": "citations", "count": 1 },
    \\    { "title": "Further reading", "parser_kind": "citations", "count": 1 },
    \\    { "title": "Quotations", "parser_kind": "citations", "count": 1 }
    \\  ],
    \\  "headings_by_level": [],
    \\  "translation_source_labels": [],
    \\  "translation_target_languages": [],
    \\  "templates_by_heading": []
    \\}
;

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

const ParsedHeadingLevelKey = struct {
    level: u8,
    title: []const u8,
};

fn parseHeadingLevelKey(key: []const u8) ?ParsedHeadingLevelKey {
    if (key.len < 4 or key[0] != 'L') return null;
    const colon = std.mem.indexOfScalar(u8, key, ':') orelse return null;
    if (colon <= 1 or colon + 1 >= key.len) return null;
    const level = std.fmt.parseInt(u8, key[1..colon], 10) catch return null;
    return .{
        .level = level,
        .title = key[colon + 1 ..],
    };
}

fn headingKindNameForTitle(profiles: []const HeadingProfile, title: []const u8) ?[]const u8 {
    for (profiles) |profile| {
        if (std.mem.eql(u8, profile.title, title)) {
            return sectionKindNameForParser(profile.parser_kind);
        }
    }
    return null;
}

fn generatedHeadingLessThan(_: void, a: GeneratedHeading, b: GeneratedHeading) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.title, b.title);
}

fn generatedHeadingLevelLessThan(_: void, a: GeneratedHeadingLevel, b: GeneratedHeadingLevel) bool {
    if (a.count != b.count) return a.count > b.count;
    if (a.level != b.level) return a.level < b.level;
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
