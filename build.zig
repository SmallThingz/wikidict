const std = @import("std");
const bootstrap_support = @import("tools/structure_tables_support.zig");
const structure_report_file = @import("shared/structure_report.zig");

pub fn build(b: *std.Build) void {
    b.graph.incremental = false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSafe;
    const test_optimize: std.builtin.OptimizeMode = .ReleaseSafe;
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
    const cli_args_mod_test = b.createModule(.{
        .root_source_file = b.path("tools/cli_args.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const required_path_mod = b.createModule(.{
        .root_source_file = b.path("tools/required_path.zig"),
        .target = target,
        .optimize = optimize,
    });
    const encoder_tool_paths_options = b.addOptions();
    const decoder_tool_paths_options = b.addOptions();
    const verifier_tool_paths_options = b.addOptions();
    const verifier_tool_paths_test_options = b.addOptions();
    const encoder_tool_paths_mod = encoder_tool_paths_options.createModule();
    const decoder_tool_paths_mod = decoder_tool_paths_options.createModule();
    const verifier_tool_paths_mod = verifier_tool_paths_options.createModule();
    const verifier_tool_paths_mod_test = verifier_tool_paths_test_options.createModule();
    const cli_args_mod_structure = b.createModule(.{
        .root_source_file = b.path("tools/cli_args.zig"),
        .target = target,
        .optimize = structure_optimize,
    });

    const zxml_dep = b.dependency("zxml", .{
        .target = target,
        .optimize = optimize,
    });
    const zxml_dep_test = b.dependency("zxml", .{
        .target = target,
        .optimize = test_optimize,
    });
    const zxml_dep_structure = b.dependency("zxml", .{
        .target = target,
        .optimize = structure_optimize,
    });
    const normalize_mod = b.createModule(.{
        .root_source_file = b.path("decoder/normalize.zig"),
        .target = target,
        .optimize = optimize,
    });
    const normalize_mod_test = b.createModule(.{
        .root_source_file = b.path("decoder/normalize.zig"),
        .target = target,
        .optimize = test_optimize,
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
    const shared_xml_decode_mod_test = b.createModule(.{
        .root_source_file = b.path("shared/xml_decode.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const shared_structure_report_mod = b.createModule(.{
        .root_source_file = b.path("shared/structure_report.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_structure_report_mod_test = b.createModule(.{
        .root_source_file = b.path("shared/structure_report.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const shared_template_dispatch_mod = b.createModule(.{
        .root_source_file = b.path("shared/template_dispatch.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_template_dispatch_mod_test = b.createModule(.{
        .root_source_file = b.path("shared/template_dispatch.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const compact_pattern_seed_mod = b.createModule(.{
        .root_source_file = b.path("shared/compact_pattern_seed.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compact_pattern_seed_mod_test = b.createModule(.{
        .root_source_file = b.path("shared/compact_pattern_seed.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const wikitext_source_mod = b.createModule(.{
        .root_source_file = b.path("encoder/wikitext.zig"),
        .target = target,
        .optimize = optimize,
    });
    wikitext_source_mod.addOptions("config", config_options);
    wikitext_source_mod.addImport("shared_xml_decode", shared_xml_decode_mod);
    const wikitext_source_mod_test = b.createModule(.{
        .root_source_file = b.path("encoder/wikitext.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    wikitext_source_mod_test.addOptions("config", config_options);
    wikitext_source_mod_test.addImport("shared_xml_decode", shared_xml_decode_mod_test);
    const blob_encoder_mod = b.addModule("blob_encoder", .{
        .root_source_file = b.path("encoder/blob_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const blob_encoder_mod_test = b.createModule(.{
        .root_source_file = b.path("encoder/blob_root.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const storage_mod = b.createModule(.{ .root_source_file = b.path("native/storage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod }} });
    storage_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    const storage_test = b.createModule(.{ .root_source_file = b.path("native/storage.zig"), .target = target, .optimize = test_optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod_test }} });
    storage_test.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    const encoder_mod_bootstrap = b.addModule("encoder_bootstrap", .{
        .root_source_file = b.path("encoder/root.zig"),
        .target = target,
        .optimize = structure_optimize,
    });
    encoder_mod_bootstrap.addImport("blob_storage", storage_mod);
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
    encoder_mod_bootstrap.addImport("blob_encoder", blob_encoder_mod);

    const structure_bin = addDirectStructureBinary(
        b,
        zxml_dep_structure.path("src/root.zig"),
        config_options.getOutput(),
        zxml_config_path,
        bootstrap_generated_tables.structure_source,
    );
    const generated_tables = if (existingValidStructureReportPath(b, "data/wiktionary-structure.bin")) |existing_structure_report|
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
    const encoder_mod = b.addModule("encoder", .{
        .root_source_file = b.path("encoder/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    encoder_mod.addImport("blob_storage", storage_mod);
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
    encoder_mod.addImport("blob_encoder", blob_encoder_mod);

    const encoder_mod_test = b.addModule("encoder_test", .{
        .root_source_file = b.path("encoder/root.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    encoder_mod_test.addImport("blob_storage", storage_test);
    encoder_mod_test.addOptions("config", config_options);
    encoder_mod_test.addImport("normalize", normalize_mod_test);
    encoder_mod_test.addImport("zxml", zxml_dep_test.module("zxml"));
    encoder_mod_test.addImport("generated_structure_tables", bootstrap_generated_tables.regular);
    encoder_mod_test.addImport("cli_args", cli_args_mod_test);
    encoder_mod_test.addImport("shared_html_entities", shared_html_entities_mod);
    encoder_mod_test.addImport("shared_xml_decode", shared_xml_decode_mod_test);
    encoder_mod_test.addImport("shared_structure_report", shared_structure_report_mod_test);
    encoder_mod_test.addImport("compact_pattern_seed", compact_pattern_seed_mod_test);
    encoder_mod_test.addImport("wikitext_source", wikitext_source_mod_test);
    encoder_mod_test.addImport("blob_encoder", blob_encoder_mod_test);

    const decoder_mod = b.addModule("decoder", .{
        .root_source_file = b.path("decoder/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const blob_decoder_mod = b.addModule("blob_decoder", .{
        .root_source_file = b.path("decoder/blob_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    blob_decoder_mod.addImport("blob_encoder", blob_encoder_mod);
    const blob_decoder_mod_test = b.createModule(.{
        .root_source_file = b.path("decoder/blob_root.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    blob_decoder_mod_test.addImport("blob_encoder", blob_encoder_mod_test);
    const blob_wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const blob_encoder_mod_wasm = b.createModule(.{
        .root_source_file = b.path("encoder/blob_root.zig"),
        .target = blob_wasm_target,
        .optimize = test_optimize,
    });
    const blob_decoder_mod_wasm = b.createModule(.{
        .root_source_file = b.path("decoder/blob_root.zig"),
        .target = blob_wasm_target,
        .optimize = test_optimize,
    });
    blob_decoder_mod_wasm.addImport("blob_encoder", blob_encoder_mod_wasm);
    decoder_mod.addOptions("config", config_options);
    decoder_mod.addImport("normalize", normalize_mod);
    decoder_mod.addImport("generated_structure_tables", generated_tables.regular);
    decoder_mod.addImport("shared_xml_decode", shared_xml_decode_mod);
    decoder_mod.addImport("shared_structure_report", shared_structure_report_mod);
    decoder_mod.addImport("template_dispatch", shared_template_dispatch_mod);
    decoder_mod.addImport("compact_pattern_seed", compact_pattern_seed_mod);
    decoder_mod.addImport("wikitext_source", wikitext_source_mod);
    decoder_mod.addImport("encoder", encoder_mod);
    decoder_mod.addImport("blob_decoder", blob_decoder_mod);
    decoder_mod.addImport("cli_args", cli_args_mod);
    const decoder_mod_test = b.addModule("decoder_test", .{
        .root_source_file = b.path("decoder/root.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    decoder_mod_test.addOptions("config", config_options);
    decoder_mod_test.addImport("normalize", normalize_mod_test);
    decoder_mod_test.addImport("encoder", encoder_mod_test);
    decoder_mod_test.addImport("blob_decoder", blob_decoder_mod_test);
    decoder_mod_test.addImport("generated_structure_tables", bootstrap_generated_tables.regular);
    decoder_mod_test.addImport("shared_xml_decode", shared_xml_decode_mod_test);
    decoder_mod_test.addImport("shared_structure_report", shared_structure_report_mod_test);
    decoder_mod_test.addImport("template_dispatch", shared_template_dispatch_mod_test);
    decoder_mod_test.addImport("compact_pattern_seed", compact_pattern_seed_mod_test);
    decoder_mod_test.addImport("wikitext_source", wikitext_source_mod_test);
    decoder_mod_test.addImport("cli_args", cli_args_mod_test);

    const encoder_exe = addCliExecutable(b, "dict-encoder", b.path("encoder/main.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = encoder_mod },
        .{ .name = "cli_args", .module = cli_args_mod },
        .{ .name = "required_path", .module = required_path_mod },
        .{ .name = "shared_structure_report", .module = shared_structure_report_mod },
        .{ .name = "tool_paths", .module = encoder_tool_paths_mod },
    });
    const decoder_exe = addCliExecutable(b, "dict-decoder", b.path("decoder/main.zig"), target, optimize, &.{
        .{ .name = "decoder", .module = decoder_mod },
        .{ .name = "cli_args", .module = cli_args_mod },
        .{ .name = "required_path", .module = required_path_mod },
        .{ .name = "tool_paths", .module = decoder_tool_paths_mod },
    });
    const verifier_exe = addCliExecutable(b, "dict-verify", b.path("tools/verifier.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = encoder_mod },
        .{ .name = "decoder", .module = decoder_mod },
        .{ .name = "zxml", .module = zxml_dep.module("zxml") },
        .{ .name = "shared_structure_report", .module = shared_structure_report_mod },
        .{ .name = "tool_paths", .module = verifier_tool_paths_mod },
    });
    const module_extract_exe = addCliExecutable(b, "dict-module-extract", b.path("lua/module_extract_main.zig"), target, optimize, &.{
        .{ .name = "zxml", .module = zxml_dep.module("zxml") },
        .{ .name = "xml_decode", .module = shared_xml_decode_mod },
    });
    const template_extract_exe = addCliExecutable(b, "dict-template-extract", b.path("lua/template_extract_main.zig"), target, optimize, &.{
        .{ .name = "zxml", .module = zxml_dep.module("zxml") },
        .{ .name = "xml_decode", .module = shared_xml_decode_mod },
    });
    const blob_build_exe = addCliExecutable(b, "dict-blob-build", b.path("tools/blob_build.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = encoder_mod },
    });
    const blob_verify_exe = addCliExecutable(b, "dict-blob-verify", b.path("tools/blob_verify.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = encoder_mod },
        .{ .name = "zxml", .module = zxml_dep.module("zxml") },
    });
    const link_blobs_exe = addCliExecutable(b, "dict-link-blobs", b.path("tools/link_blobs.zig"), target, optimize, &.{.{ .name = "encoder", .module = encoder_mod }});
    addPublicRunStep(b, "link-blobs", "Replace static call names with shared symbolic operands", addRunArtifactCommand(b, link_blobs_exe, &.{}, b.args), &.{});
    const aot_exe = addCliExecutable(b, "dict-aot-build", b.path("lua/aot_build_main.zig"), target, optimize, &.{});
    aot_exe.root_module.link_libc = true;
    aot_exe.use_llvm = true;
    aot_exe.use_lld = true;
    addPublicRunStep(b, "compile-aot", "Compile extracted Lua into sharded native AOT source", addRunArtifactCommand(b, aot_exe, &.{}, b.args), &.{});
    const redirects_exe = addCliExecutable(b, "dict-runtime-redirects", b.path("tools/runtime_redirects.zig"), target, optimize, &.{ .{ .name = "zxml", .module = zxml_dep.module("zxml") }, .{ .name = "xml_decode", .module = shared_xml_decode_mod } });
    addPublicRunStep(b, "extract-runtime-redirects", "Extract semantic module redirect dependencies", addRunArtifactCommand(b, redirects_exe, &.{}, b.args), &.{});
    const pages_exe = addCliExecutable(b, "dict-runtime-pages", b.path("tools/runtime_pages.zig"), target, optimize, &.{ .{ .name = "encoder", .module = encoder_mod }, .{ .name = "zxml", .module = zxml_dep.module("zxml") } });
    addPublicRunStep(b, "extract-runtime-pages", "Extract auxiliary wiki source dependencies", addRunArtifactCommand(b, pages_exe, &.{}, b.args), &.{});
    const pipeline_paths = b.addOptions();
    pipeline_paths.addOptionPath("pages", pages_exe.getEmittedBin());
    pipeline_paths.addOptionPath("linker", link_blobs_exe.getEmittedBin());
    pipeline_paths.addOptionPath("redirects", redirects_exe.getEmittedBin());
    pipeline_paths.addOptionPath("modules", module_extract_exe.getEmittedBin());
    pipeline_paths.addOptionPath("templates", template_extract_exe.getEmittedBin());
    pipeline_paths.addOptionPath("aot", aot_exe.getEmittedBin());
    pipeline_paths.addOption([]const u8, "zig", b.graph.zig_exe);
    pipeline_paths.addOption([]const u8, "project_root", b.pathFromRoot("."));
    pipeline_paths.addOptionPath("blobs", blob_build_exe.getEmittedBin());
    const pipeline_exe = addCliExecutable(b, "dict-runtime-build", b.path("tools/runtime_build.zig"), target, optimize, &.{.{ .name = "pipeline_paths", .module = pipeline_paths.createModule() }});
    addPublicRunStep(b, "build-runtime", "Extract templates/modules and build the native Lua AOT worker", addRunArtifactCommand(b, pipeline_exe, &.{}, b.args), &.{});
    addPublicRunStep(b, "build-dictionary", "Build dictionary blobs plus their shared native Lua runtime in one coordinated pipeline", addRunArtifactCommand(b, pipeline_exe, &.{"--with-blobs"}, b.args), &.{});
    const blob_files_mod = b.createModule(.{ .root_source_file = b.path("encoder/blob_files.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod }} });
    const blob_files_mod_test = b.createModule(.{ .root_source_file = b.path("encoder/blob_files.zig"), .target = target, .optimize = test_optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod_test }} });
    blob_files_mod.addImport("blob_storage", storage_mod);
    blob_files_mod_test.addImport("blob_storage", storage_test);
    const blob_query_exe = addCliExecutable(b, "dict", b.path("frontend/main.zig"), target, optimize, &.{
        .{ .name = "blob_encoder", .module = blob_encoder_mod },
        .{ .name = "blob_decoder", .module = blob_decoder_mod },
        .{ .name = "blob_files", .module = blob_files_mod },
        .{ .name = "blob_storage", .module = storage_mod },
        .{ .name = "html_entities", .module = b.createModule(.{ .root_source_file = b.path("shared/html_entities.zig"), .target = target, .optimize = optimize }) },
    });
    // Locale-aware terminal cell widths use libc; lld supports current host crt objects.
    blob_query_exe.root_module.link_libc = true;
    blob_query_exe.use_llvm = true;
    blob_query_exe.use_lld = true;
    b.installArtifact(blob_query_exe);
    encoder_tool_paths_options.addOption([]const u8, "structure_bin_path", b.pathFromRoot("zig-out/bin/dict-structure"));
    decoder_tool_paths_options.addOption([]const u8, "encoder_bin_path", b.pathFromRoot("zig-out/bin/dict-encoder"));
    verifier_tool_paths_options.addOption([]const u8, "structure_bin_path", b.pathFromRoot("zig-out/bin/dict-structure"));
    verifier_tool_paths_options.addOption([]const u8, "encoder_bin_path", b.pathFromRoot("zig-out/bin/dict-encoder"));
    verifier_tool_paths_options.addOption([]const u8, "decoder_bin_path", b.pathFromRoot("zig-out/bin/dict-decoder"));
    verifier_tool_paths_test_options.addOption([]const u8, "structure_bin_path", "dict-structure");
    verifier_tool_paths_test_options.addOption([]const u8, "encoder_bin_path", "dict-encoder");
    verifier_tool_paths_test_options.addOption([]const u8, "decoder_bin_path", "dict-decoder");

    const structure_install = b.addInstallBinFile(structure_bin, "dict-structure");
    const encoder_install = b.addInstallArtifact(encoder_exe, .{});
    const decoder_install = b.addInstallArtifact(decoder_exe, .{});
    const verifier_install = b.addInstallArtifact(verifier_exe, .{});
    b.getInstallStep().dependOn(&structure_install.step);
    b.getInstallStep().dependOn(&encoder_install.step);
    b.getInstallStep().dependOn(&decoder_install.step);
    b.getInstallStep().dependOn(&verifier_install.step);

    const structure_run = addDirectToolRunCommand(b, structure_bin, &.{}, b.args);
    addPublicRunStep(b, "structure", "Analyze Wiktionary structure", structure_run, &.{});

    const encode_run = addRunArtifactCommand(b, encoder_exe, &.{}, b.args);
    addPublicRunStep(b, "encode", "Run the encoder CLI", encode_run, &.{&structure_install.step});

    const decode_run = addRunArtifactCommand(b, decoder_exe, &.{}, b.args);
    addPublicRunStep(b, "decode", "Run the decoder CLI", decode_run, &.{ &encoder_install.step, &structure_install.step });

    const verify_run = addRunArtifactCommand(b, verifier_exe, &.{}, b.args);
    addPublicRunStep(b, "verify", "Verify dictionary raw entries against the XML dump", verify_run, &.{ &decoder_install.step, &encoder_install.step, &structure_install.step });

    const module_extract_run = addRunArtifactCommand(b, module_extract_exe, &.{}, b.args);
    addPublicRunStep(b, "extract-modules", "Extract Scribunto modules from a Wiktionary XML dump", module_extract_run, &.{});

    const template_extract_run = addRunArtifactCommand(b, template_extract_exe, &.{}, b.args);
    addPublicRunStep(b, "extract-templates", "Extract template pages from a Wiktionary XML dump", template_extract_run, &.{});

    const blob_build_run = addRunArtifactCommand(b, blob_build_exe, &.{}, b.args);
    addPublicRunStep(b, "build-blobs", "Build per-language and feature Wiktionary blobs", blob_build_run, &.{});

    const blob_verify_run = addRunArtifactCommand(b, blob_verify_exe, &.{}, b.args);
    addPublicRunStep(b, "verify-blobs", "Verify Wiktionary blobs against the XML dump", blob_verify_run, &.{});

    const blob_query_run = addRunArtifactCommand(b, blob_query_exe, &.{}, b.args);
    addPublicRunStep(b, "query-blobs", "Query per-language and feature Wiktionary blobs", blob_query_run, &.{});
    addPublicRunStep(b, "dict", "Run the dictionary frontend CLI", blob_query_run, &.{});

    const web_build = b.addSystemCommand(&.{ "bun", "run", "build" });
    web_build.setCwd(b.path("frontend/web"));
    b.step("frontend", "Rebuild the self-contained web UI (bun install first)").dependOn(&web_build.step);

    const test_runner = b.path("tools/test_runner.zig");

    const encoder_tests = b.addTest(.{
        .root_module = encoder_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const blob_encoder_tests = b.addTest(.{
        .root_module = blob_encoder_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const decoder_tests = b.addTest(.{
        .root_module = decoder_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const blob_decoder_tests = b.addTest(.{
        .root_module = blob_decoder_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const structure_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/structure_analyzer.zig"),
            .target = target,
            .optimize = test_optimize,
            .imports = &.{
                .{ .name = "encoder", .module = encoder_mod_test },
                .{ .name = "zxml", .module = zxml_dep_test.module("zxml") },
                .{ .name = "shared_structure_report", .module = shared_structure_report_mod_test },
                .{ .name = "compact_pattern_seed", .module = compact_pattern_seed_mod_test },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const structure_tables_support_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/structure_tables_support.zig"),
            .target = target,
            .optimize = test_optimize,
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
            .optimize = test_optimize,
            .imports = &.{
                .{ .name = "encoder", .module = encoder_mod_test },
                .{ .name = "decoder", .module = decoder_mod_test },
                .{ .name = "zxml", .module = zxml_dep_test.module("zxml") },
                .{ .name = "shared_structure_report", .module = shared_structure_report_mod_test },
                .{ .name = "tool_paths", .module = verifier_tool_paths_mod_test },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const blob_query_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("frontend/main.zig"),
            .target = target,
            .optimize = test_optimize,
            .imports = &.{
                .{ .name = "blob_encoder", .module = blob_encoder_mod_test },
                .{ .name = "blob_decoder", .module = blob_decoder_mod_test },
                .{ .name = "blob_files", .module = blob_files_mod_test },
                .{ .name = "blob_storage", .module = storage_test },
                .{ .name = "html_entities", .module = b.createModule(.{ .root_source_file = b.path("shared/html_entities.zig"), .target = target, .optimize = test_optimize }) },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    blob_query_tests.root_module.link_libc = true;
    blob_query_tests.use_llvm = true;
    blob_query_tests.use_lld = true;
    const lua_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lua/tests.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zxml", .module = zxml_dep_test.module("zxml") },
                .{ .name = "xml_decode", .module = shared_xml_decode_mod_test },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const lua_program_data_test_mod = b.createModule(.{
        .root_source_file = b.path("lua/aot/program_data.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const lua_static_keys_test_mod = b.createModule(.{
        .root_source_file = b.path("lua/abi/static_keys.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const lua_globals_test_mod = b.createModule(.{
        .root_source_file = b.path("lua/abi/globals.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const lua_wikitext_preprocess_test_mod = b.createModule(.{
        .root_source_file = b.path("lua/wikitext/preprocess.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const lua_wikitext_expression_test_mod = b.createModule(.{
        .root_source_file = b.path("lua/wikitext/expression.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const zig_runtime_test_mod = b.createModule(.{
        .root_source_file = b.path("lua/runtime/core.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    zig_runtime_test_mod.addImport("lua_program_data", lua_program_data_test_mod);
    zig_runtime_test_mod.addImport("lua_static_keys", lua_static_keys_test_mod);
    const aot_stdlib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lua/runtime/stdlib.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zig_runtime", .module = zig_runtime_test_mod },
                .{ .name = "lua_globals", .module = lua_globals_test_mod },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const aot_ustring_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lua/runtime/ustring.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zig_runtime", .module = zig_runtime_test_mod }},
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const aot_scribunto_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lua/runtime/scribunto.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zig_runtime", .module = zig_runtime_test_mod },
                .{ .name = "zig_stdlib", .module = aot_stdlib_tests.root_module },
                .{ .name = "lua_wikitext_preprocess", .module = lua_wikitext_preprocess_test_mod },
                .{ .name = "lua_wikitext_expression", .module = lua_wikitext_expression_test_mod },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const aot_wikitext_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lua/runtime/wikitext.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zig_runtime", .module = zig_runtime_test_mod },
                .{ .name = "zig_stdlib", .module = aot_stdlib_tests.root_module },
                .{ .name = "lua_wikitext_preprocess", .module = lua_wikitext_preprocess_test_mod },
                .{ .name = "lua_wikitext_expression", .module = lua_wikitext_expression_test_mod },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const aot_module_registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lua/runtime/module_registry_test.zig"),
            .target = target,
            .optimize = test_optimize,
            .imports = &.{.{ .name = "zig_runtime", .module = zig_runtime_test_mod }},
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const blob_wasm_smoke = b.addObject(.{
        .name = "dict-blob-wasm-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/blob_wasm_smoke.zig"),
            .target = blob_wasm_target,
            .optimize = test_optimize,
            .imports = &.{
                .{ .name = "blob_decoder", .module = blob_decoder_mod_wasm },
            },
        }),
    });
    const run_encoder_tests = b.addRunArtifact(encoder_tests);
    const run_blob_encoder_tests = b.addRunArtifact(blob_encoder_tests);
    const run_decoder_tests = b.addRunArtifact(decoder_tests);
    const run_blob_decoder_tests = b.addRunArtifact(blob_decoder_tests);
    const run_structure_tests = b.addRunArtifact(structure_tests);
    const run_structure_tables_support_tests = b.addRunArtifact(structure_tables_support_tests);
    const run_verifier_tests = b.addRunArtifact(verifier_tests);
    const run_blob_query_tests = b.addRunArtifact(blob_query_tests);
    const run_lua_tests = b.addRunArtifact(lua_tests);
    const run_aot_stdlib_tests = b.addRunArtifact(aot_stdlib_tests);
    const run_aot_ustring_tests = b.addRunArtifact(aot_ustring_tests);
    const run_aot_scribunto_tests = b.addRunArtifact(aot_scribunto_tests);
    const run_aot_wikitext_tests = b.addRunArtifact(aot_wikitext_tests);
    const run_aot_module_registry_tests = b.addRunArtifact(aot_module_registry_tests);

    // Running every test compile in parallel is enough to get the larger codegen-heavy
    // test binaries terminated under ReleaseFast on typical developer machines. Keep
    // the public `zig build test` step deterministic and low-memory by serializing
    // test compilation/execution through one chain.
    blob_encoder_tests.step.dependOn(&run_encoder_tests.step);
    decoder_tests.step.dependOn(&run_blob_encoder_tests.step);
    blob_decoder_tests.step.dependOn(&run_decoder_tests.step);
    structure_tests.step.dependOn(&run_blob_decoder_tests.step);
    structure_tables_support_tests.step.dependOn(&run_structure_tests.step);
    verifier_tests.step.dependOn(&run_structure_tables_support_tests.step);
    blob_query_tests.step.dependOn(&run_verifier_tests.step);
    lua_tests.step.dependOn(&run_blob_query_tests.step);
    aot_stdlib_tests.step.dependOn(&run_lua_tests.step);
    aot_ustring_tests.step.dependOn(&run_aot_stdlib_tests.step);
    aot_scribunto_tests.step.dependOn(&run_aot_ustring_tests.step);
    aot_wikitext_tests.step.dependOn(&run_aot_scribunto_tests.step);
    aot_module_registry_tests.step.dependOn(&run_aot_wikitext_tests.step);

    const test_step = b.step("test", "Run encoder, decoder, structure, Lua, and tooling tests");
    blob_wasm_smoke.step.dependOn(&run_aot_module_registry_tests.step);
    test_step.dependOn(&blob_wasm_smoke.step);
    const media_fetch_exe = addCliExecutable(b, "dict-media-fetch", b.path("tools/media_fetch.zig"), target, optimize, &.{ .{ .name = "media_types", .module = b.createModule(.{ .root_source_file = b.path("frontend/media_types.zig"), .target = target, .optimize = optimize }) }, .{ .name = "encoder", .module = encoder_mod } });
    addPublicRunStep(b, "fetch-media", "Download bounded attributed Wikimedia assets for an export", addRunArtifactCommand(b, media_fetch_exe, &.{}, b.args), &.{});
    const runtime_test_exe = addCliExecutable(b, "dict-runtime-integration-test", b.path("tools/runtime_integration_test.zig"), b.graph.host, test_optimize, &.{});
    const runtime_test_run = b.addRunArtifact(runtime_test_exe);
    runtime_test_run.addFileArg(blob_query_exe.getEmittedBin());
    runtime_test_run.addFileArg(pipeline_exe.getEmittedBin());
    runtime_test_run.addArg(b.pathFromRoot(".zig-cache"));
    runtime_test_run.step.dependOn(&blob_wasm_smoke.step);
    b.step("test-runtime", "Exercise extraction and native Lua AOT rendering end to end").dependOn(&runtime_test_run.step);
    const reader_test_exe = addCliExecutable(b, "dict-reader-integration-test", b.path("tools/reader_integration_test.zig"), b.graph.host, test_optimize, &.{});
    const reader_test_run = b.addRunArtifact(reader_test_exe);
    reader_test_run.addFileArg(blob_query_exe.getEmittedBin());
    reader_test_run.addFileArg(blob_build_exe.getEmittedBin());
    reader_test_run.addArg(b.pathFromRoot(".zig-cache"));
    reader_test_run.step.dependOn(&runtime_test_run.step);
    b.step("test-reader", "Exercise optional-companion reading through the real CLI").dependOn(&reader_test_run.step);
    const index_blobs_exe = addCliExecutable(b, "dict-index-blobs", b.path("tools/index_blobs.zig"), target, optimize, &.{.{ .name = "blob_storage", .module = storage_mod }});
    index_blobs_exe.root_module.link_libc = true;
    index_blobs_exe.use_llvm = true;
    index_blobs_exe.use_lld = true;
    addPublicRunStep(b, "index-blobs", "Build or reuse external raw/XZ record indexes after compression", addRunArtifactCommand(b, index_blobs_exe, &.{}, b.args), &.{});
    const storage_exe = addCliExecutable(b, "dict-storage-integration-test", b.path("tools/storage_integration_test.zig"), target, test_optimize, &.{ .{ .name = "blob_encoder", .module = blob_encoder_mod_test }, .{ .name = "blob_storage", .module = storage_test } });
    storage_exe.root_module.link_libc = true;
    storage_exe.use_llvm = true;
    storage_exe.use_lld = true;
    const storage_run = b.addRunArtifact(storage_exe);
    storage_run.addArg(b.pathFromRoot(".zig-cache"));
    const storage_unit = b.addTest(.{ .root_module = storage_test, .test_runner = .{ .path = test_runner, .mode = .simple } });
    storage_unit.root_module.link_libc = true;
    storage_unit.use_llvm = true;
    storage_unit.use_lld = true;
    const storage_unit_run = b.addRunArtifact(storage_unit);
    storage_unit_run.step.dependOn(&reader_test_run.step);
    storage_run.step.dependOn(&storage_unit_run.step);
    b.step("test-storage", "Exercise after-compression indexes and selective real XZ block decoding").dependOn(&storage_run.step);
    const http_exe = addCliExecutable(b, "dict-http-integration-test", b.path("tools/http_integration_test.zig"), target, test_optimize, &.{.{ .name = "blob_encoder", .module = blob_encoder_mod_test }});
    http_exe.root_module.link_libc = true;
    http_exe.use_llvm = true;
    http_exe.use_lld = true;
    const http_run = b.addRunArtifact(http_exe);
    http_run.addFileArg(blob_query_exe.getEmittedBin());
    http_run.addArg(b.pathFromRoot(".zig-cache"));
    http_run.step.dependOn(&storage_run.step);
    b.step("test-http", "Exercise live HTTP/1.1 against raw, compressed and cached data").dependOn(&http_run.step);
    if (target.result.os.tag == b.graph.host.result.os.tag and target.result.cpu.arch == b.graph.host.result.cpu.arch) test_step.dependOn(&http_run.step);
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
    run_cmd.setCwd(b.path("."));
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
    run_cmd.setCwd(b.path("."));
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
    if (!passthroughArgsRequestHelp(b.args)) {
        for (deps) |dep| step.dependOn(dep);
    }
    step.dependOn(&run_cmd.step);
}

fn passthroughArgsRequestHelp(args: ?[]const []const u8) bool {
    const actual = args orelse return false;
    for (actual) |arg| {
        if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return true;
    }
    return false;
}

fn existingBuildPath(b: *std.Build, relative_path: []const u8) ?std.Build.LazyPath {
    _ = std.Io.Dir.cwd().statFile(b.graph.io, relative_path, .{}) catch return null;
    return b.path(relative_path);
}

fn existingValidStructureReportPath(b: *std.Build, relative_path: []const u8) ?std.Build.LazyPath {
    _ = existingBuildPath(b, relative_path) orelse return null;
    const valid = structure_report_file.hasValidMagicAtPath(b.graph.io, relative_path) catch return null;
    if (!valid) return null;
    return b.path(relative_path);
}

const GeneratedStructureModules = struct {
    regular: *std.Build.Module,
    structure: *std.Build.Module,
    regular_source: std.Build.LazyPath,
    structure_source: std.Build.LazyPath,
};

const bootstrap_heading_profiles = [_]bootstrap_support.LegacyHeadingProfile{
    .{ .title = "English", .parser_kind = "language-root", .count = 1 },
    .{ .title = "Noun", .parser_kind = "part-of-speech", .count = 1 },
    .{ .title = "Verb", .parser_kind = "part-of-speech", .count = 1 },
    .{ .title = "Adjective", .parser_kind = "part-of-speech", .count = 1 },
    .{ .title = "Proper noun", .parser_kind = "part-of-speech", .count = 1 },
    .{ .title = "Etymology", .parser_kind = "etymology", .count = 1 },
    .{ .title = "Pronunciation", .parser_kind = "pronunciation", .count = 1 },
    .{ .title = "Alternative forms", .parser_kind = "alternative-forms", .count = 1 },
    .{ .title = "Translations", .parser_kind = "translations", .count = 1 },
    .{ .title = "Derived terms", .parser_kind = "relations", .count = 1 },
    .{ .title = "Synonyms", .parser_kind = "relations", .count = 1 },
    .{ .title = "Usage notes", .parser_kind = "notes", .count = 1 },
    .{ .title = "Conjugation", .parser_kind = "inflection", .count = 1 },
    .{ .title = "Descendants", .parser_kind = "descendants", .count = 1 },
    .{ .title = "See also", .parser_kind = "navigation", .count = 1 },
    .{ .title = "References", .parser_kind = "citations", .count = 1 },
    .{ .title = "Further reading", .parser_kind = "citations", .count = 1 },
    .{ .title = "Quotations", .parser_kind = "citations", .count = 1 },
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
    structure_path: std.Build.LazyPath,
) GeneratedStructureModules {
    const codegen_run = b.addSystemCommand(&.{"/usr/bin/env"});
    codegen_run.addFileArg(codegen_bin);
    codegen_run.addArg("--input");
    codegen_run.addFileArg(structure_path);
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
    compile.addArgs(&.{ "--dep", "compact_pattern_seed", "--dep", "shared_structure_report" });
    compile.addPrefixedFileArg("-Mroot=", b.path("tools/structure_tables_codegen.zig"));
    compile.addArg("-OReleaseFast");
    compile.addPrefixedFileArg("-Mcompact_pattern_seed=", b.path("shared/compact_pattern_seed.zig"));
    compile.addPrefixedFileArg("-Mshared_structure_report=", b.path("shared/structure_report.zig"));
    const output = compile.addPrefixedOutputFileArg("-femit-bin=", "dict-structure-tables-codegen");
    return output;
}

fn addDirectStructureBinary(
    b: *std.Build,
    zxml_root_path: std.Build.LazyPath,
    config_path: std.Build.LazyPath,
    config0_path: std.Build.LazyPath,
    bootstrap_tables_path: std.Build.LazyPath,
) std.Build.LazyPath {
    const compile = b.addSystemCommand(&.{ b.graph.zig_exe, "build-exe", "-OReleaseFast" });
    compile.addArgs(&.{ "--dep", "encoder", "--dep", "zxml", "--dep", "compact_pattern_seed", "--dep", "wikitext_source", "--dep", "shared_structure_report" });
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
    compile.addArgs(&.{ "--dep", "config=config0" });
    compile.addPrefixedFileArg("-Mzxml=", zxml_root_path);
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
    zxml_root_path: std.Build.LazyPath,
    config_path: std.Build.LazyPath,
    config0_path: std.Build.LazyPath,
    regular_tables_path: std.Build.LazyPath,
    tool_paths_path: std.Build.LazyPath,
) std.Build.LazyPath {
    const compile = b.addSystemCommand(&.{ b.graph.zig_exe, "build-exe", "-OReleaseFast" });
    compile.addArgs(&.{ "--dep", "encoder", "--dep", "decoder", "--dep", "zxml", "--dep", "compact_pattern_seed", "--dep", "tool_paths", "--dep", "wikitext_source", "--dep", "shared_structure_report" });
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
    compile.addPrefixedFileArg("-Mzxml=", zxml_root_path);
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
    var bootstrap_build = try bootstrap_support.buildDataFromInputsAlloc(b.allocator, .{
        .heading_profiles = &bootstrap_heading_profiles,
    });
    defer bootstrap_build.deinit(b.allocator);
    return bootstrap_support.generateStructureTableSourceAlloc(
        b.allocator,
        "build.zig bootstrap defaults",
        bootstrap_build,
    );
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
