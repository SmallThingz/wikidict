const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.Optimize,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .safe;
    const test_optimize: std.builtin.Optimize = .safe;
    const namespace_registry_mod = namespaceRegistryModule(b, target, optimize);
    const namespace_registry_test_mod = namespaceRegistryModule(b, target, test_optimize);
    // Reuse the registry graph's exact Unicode modules in reader consumers.
    const unicode_lower_mod = namespace_registry_mod.import_table.get("unicode_lower").?;
    const unicode_lower_test_mod = namespace_registry_test_mod.import_table.get("unicode_lower").?;
    const language_metadata_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/parser/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const language_metadata_parser_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/parser/root.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    // Build-only occurrence coordinates are shared by producer and receiver.
    const missing_dependency_mod = b.createModule(.{ .root_source_file = b.path("src/shared/missing_dependency.zig"), .target = target, .optimize = optimize });
    const missing_dependency_test_mod = b.createModule(.{ .root_source_file = b.path("src/shared/missing_dependency.zig"), .target = target, .optimize = test_optimize });
    const shared_xml_decode_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/xml_decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_xml_decode_mod_test = b.createModule(.{
        .root_source_file = b.path("src/shared/xml_decode.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const wikimedia_dump_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/wikimedia_dump.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const wikimedia_dump_mod_test = b.createModule(.{
        .root_source_file = b.path("src/shared/wikimedia_dump.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
    });
    // Parent bundle processes share the worker's bounded single-write logger.
    // This standalone module does not pull the Lua runtime into blob building.
    const build_diagnostics_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/runtime/work_stats.zig"),
        .target = target,
        .optimize = optimize,
    });
    const build_diagnostics_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/runtime/work_stats.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    const bundle_protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/bundle_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bundle_protocol_mod_test = b.createModule(.{
        .root_source_file = b.path("src/lua/bundle_protocol.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    const blob_encoder_mod = b.addModule("blob_encoder", .{
        .root_source_file = b.path("src/encoder/blob_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const blob_encoder_mod_test = b.createModule(.{
        .root_source_file = b.path("src/encoder/blob_root.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const blob_xz_mod = b.createModule(.{ .root_source_file = b.path("src/native/xz.zig"), .target = target, .optimize = optimize });
    const storage_mod = b.createModule(.{ .root_source_file = b.path("src/native/storage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod }} });
    const lzma = b.addTranslateC(.{ .root_source_file = b.path("src/native/lzma.h"), .target = target, .optimize = optimize });
    lzma.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    storage_mod.addImport("lzma", lzma.createModule());
    blob_xz_mod.addImport("lzma", lzma.createModule());
    const storage_test = b.createModule(.{ .root_source_file = b.path("src/native/storage.zig"), .target = target, .optimize = test_optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod_test }} });
    storage_test.addImport("lzma", lzma.createModule());
    const encoder_mod = b.addModule("encoder", .{
        .root_source_file = b.path("src/encoder/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    encoder_mod.addImport("namespace_registry", namespace_registry_mod);
    encoder_mod.addImport("shared_xml_decode", shared_xml_decode_mod);
    encoder_mod.addImport("blob_encoder", blob_encoder_mod);
    encoder_mod.addImport("build_diagnostics", build_diagnostics_mod);
    encoder_mod.addImport("missing_dependency", missing_dependency_mod);

    const encoder_mod_test = b.addModule("encoder_test", .{
        .root_source_file = b.path("src/encoder/root.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    encoder_mod_test.addImport("namespace_registry", namespace_registry_test_mod);
    encoder_mod_test.addImport("shared_xml_decode", shared_xml_decode_mod_test);
    encoder_mod_test.addImport("blob_encoder", blob_encoder_mod_test);
    encoder_mod_test.addImport("build_diagnostics", build_diagnostics_test_mod);
    encoder_mod_test.addImport("missing_dependency", missing_dependency_test_mod);

    const blob_decoder_mod = b.addModule("blob_decoder", .{
        .root_source_file = b.path("src/decoder/blob_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    blob_decoder_mod.addImport("blob_encoder", blob_encoder_mod);
    const blob_decoder_mod_test = b.createModule(.{
        .root_source_file = b.path("src/decoder/blob_root.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    blob_decoder_mod_test.addImport("blob_encoder", blob_encoder_mod_test);
    const blob_wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const blob_encoder_mod_wasm = b.createModule(.{
        .root_source_file = b.path("src/encoder/blob_root.zig"),
        .target = blob_wasm_target,
        .optimize = test_optimize,
    });
    const blob_decoder_mod_wasm = b.createModule(.{
        .root_source_file = b.path("src/decoder/blob_root.zig"),
        .target = blob_wasm_target,
        .optimize = test_optimize,
    });
    blob_decoder_mod_wasm.addImport("blob_encoder", blob_encoder_mod_wasm);

    const lua_usage_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/usage.zig"),
        .target = target,
        .optimize = optimize,
    });
    lua_usage_mod.addImport("namespace_registry", namespace_registry_mod);
    lua_usage_mod.addImport("missing_dependency", missing_dependency_mod);
    const module_extract_exe = addCliExecutable(b, "dict-module-extract", b.path("src/lua/module_extract_main.zig"), target, optimize, &.{
        .{ .name = "xml_decode", .module = shared_xml_decode_mod },
        .{ .name = "lua_usage", .module = lua_usage_mod },
        .{ .name = "wikimedia_dump", .module = wikimedia_dump_mod },
    });
    module_extract_exe.root_module.addImport("namespace_registry", namespace_registry_mod);
    module_extract_exe.root_module.link_libc = true;
    module_extract_exe.root_module.linkSystemLibrary("bz2", .{});
    module_extract_exe.root_module.linkSystemLibrary("zstd", .{});
    const page_title_index_exe = addCliExecutable(b, "dict-page-title-index", b.path("tools/page_title_index.zig"), target, optimize, &.{
        .{ .name = "wikimedia_dump", .module = wikimedia_dump_mod },
    });
    page_title_index_exe.root_module.link_libc = true;
    page_title_index_exe.root_module.linkSystemLibrary("bz2", .{});
    page_title_index_exe.root_module.linkSystemLibrary("zstd", .{});
    const blob_build_exe = addCliExecutable(b, "dict-blob-build", b.path("tools/blob_build.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = encoder_mod },
        .{ .name = "lua_parser", .module = language_metadata_parser_mod },
        .{ .name = "xml_decode", .module = shared_xml_decode_mod },
        .{ .name = "wikimedia_dump", .module = wikimedia_dump_mod },
        .{ .name = "bundle_protocol", .module = bundle_protocol_mod },
        .{ .name = "build_diagnostics", .module = build_diagnostics_mod },
    });
    const captured_writer_options = b.addOptions();
    captured_writer_options.addOption([]const u8, "source_fingerprint", b.option([]const u8, "captured-source-fingerprint", "Exact immutable source binding for retained-page diagnostics") orelse "");
    blob_build_exe.root_module.addOptions("captured_writer_options", captured_writer_options);
    blob_build_exe.root_module.link_libc = true;
    blob_build_exe.root_module.linkSystemLibrary("bz2", .{});
    blob_build_exe.root_module.linkSystemLibrary("zstd", .{});
    addPublicRunStep(b, "build-blobs", "Encode blobs with an already compiled bundle expander", addRunArtifactCommand(b, blob_build_exe, &.{}), &.{});
    blob_build_exe.root_module.addImport("namespace_registry", namespace_registry_mod);
    const blob_merge_exe = addCliExecutable(b, "dict-blob-merge", b.path("tools/blob_merge.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = blob_encoder_mod },
    });
    blob_merge_exe.root_module.addImport("xz", blob_xz_mod);
    blob_merge_exe.root_module.link_libc = true;
    addPublicRunStep(b, "merge-blobs", "Merge non-overlapping compiled blob shards", addRunArtifactCommand(b, blob_merge_exe, &.{}), &.{});
    const blob_verify_exe = addCliExecutable(b, "dict-blob-verify", b.path("tools/blob_verify.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = blob_encoder_mod },
    });
    blob_verify_exe.root_module.addImport("xz", blob_xz_mod);
    blob_verify_exe.root_module.link_libc = true;

    const prepare_captured_writer = b.step("prepare-captured-writer", "Prepare the existing blob tool for authenticated retained-page diagnostics");
    const prepare_blob_tools = b.step("prepare-blob-tools", "Prepare native blob build, merge and verification tools");
    for ([_]*std.Build.Step.Compile{ blob_build_exe, blob_merge_exe, blob_verify_exe }) |artifact| {
        const install = b.addInstallArtifact(artifact, .{});
        prepare_blob_tools.dependOn(&install.step);
        if (artifact == blob_build_exe) prepare_captured_writer.dependOn(&install.step);
    }

    const llvm_obj = b.addObject(.{
        .name = "dict-llvm-build-core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua/llvm_build_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    llvm_obj.root_module.addImport("namespace_registry", namespace_registry_mod);
    llvm_obj.root_module.addImport("missing_dependency", missing_dependency_mod);
    const llvm_exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    llvm_exe_mod.addCSourceFile(.{
        .file = b.path("tools/llvm_build_main.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    llvm_exe_mod.addObject(llvm_obj);
    llvm_exe_mod.linkSystemLibrary("LLVM", .{ .use_pkg_config = .no });
    const llvm_exe = b.addExecutable(.{
        .name = "dict-llvm-build",
        .root_module = llvm_exe_mod,
        .use_llvm = true,
        .use_lld = true,
    });
    addPublicRunStep(b, "extract-lua", "Extract Lua modules or rebuild Lua usage metadata", addRunArtifactCommand(b, module_extract_exe, &.{}), &.{});
    addPublicRunStep(b, "index-pages", "Build the mmap page-title index from page-index.tsv", addRunArtifactCommand(b, page_title_index_exe, &.{}), &.{});
    addPublicRunStep(b, "compile-lua", "Compile extracted Lua AST directly to LLVM bitcode", addRunArtifactCommand(b, llvm_exe, &.{}), &.{});
    const pipeline_paths = b.addOptions();
    const worker_object = bundleWorkerObject(b);
    pipeline_paths.addOptionPath("worker_object", worker_object.getEmittedBin());
    const value_leaf_object = bundleValueLeafObject(b);
    // Preserve the former build-obj producer's object+bitcode outputs. Only
    // bitcode is consumed; the leaf object must never be linked into a worker.
    _ = value_leaf_object.getEmittedBin();
    pipeline_paths.addOptionPath("value_leaf_bc", value_leaf_object.getEmittedLlvmBc());
    const native_inputs = b.addWriteFiles();
    pipeline_paths.addOptionPath("worker_main_c", native_inputs.addCopyFile(
        b.path("src/lua/bundle_worker_main.c"),
        "bundle_worker_main.c",
    ));
    pipeline_paths.addOptionPath("modules", module_extract_exe.getEmittedBin());
    pipeline_paths.addOptionPath("llvm", llvm_exe.getEmittedBin());
    pipeline_paths.addOption([]const u8, "zig", b.graph.zig_exe);
    pipeline_paths.addOption([]const u8, "clang", "clang");
    pipeline_paths.addOptionPathUntracked("project_root", b.path("."));
    pipeline_paths.addOptionPath("blobs", blob_build_exe.getEmittedBin());
    const pipeline_exe = addCliExecutable(b, "dict-bundle-build", b.path("tools/bundle_build.zig"), target, optimize, &.{.{ .name = "pipeline_paths", .module = pipeline_paths.createModule() }});
    addPublicRunStep(b, "build-dictionary", "Pre-expand templates/modules and emit data-only dictionary blobs", addRunArtifactCommand(b, pipeline_exe, &.{}), &.{});
    const blob_files_mod = b.createModule(.{ .root_source_file = b.path("src/encoder/blob_files.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod }} });
    const blob_files_mod_test = b.createModule(.{ .root_source_file = b.path("src/encoder/blob_files.zig"), .target = target, .optimize = test_optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod_test }} });
    // Encoder and readers share one module identity for this source file.
    blob_verify_exe.root_module.addImport("blob_files", blob_files_mod);
    encoder_mod.addImport("blob_files", blob_files_mod);
    encoder_mod_test.addImport("blob_files", blob_files_mod_test);
    const reader_name = if (target.result.os.tag == .windows or target.result.os.tag == .wasi) "dict" else "wikidict";
    const blob_query_exe = addCliExecutable(b, reader_name, b.path("src/frontend/main.zig"), target, optimize, &.{
        .{ .name = "blob_encoder", .module = blob_encoder_mod },
        .{ .name = "blob_decoder", .module = blob_decoder_mod },
        .{ .name = "blob_files", .module = blob_files_mod },
        .{ .name = "blob_storage", .module = storage_mod },
        .{ .name = "unicode_lower", .module = unicode_lower_mod },
    });
    // Locale-aware terminal cell widths use libc; lld supports current host crt objects.
    blob_query_exe.root_module.link_libc = true;
    blob_query_exe.use_llvm = true;
    blob_query_exe.use_lld = true;
    const cli_install = b.addInstallArtifact(blob_query_exe, .{});
    b.getInstallStep().dependOn(&cli_install.step);
    const cli_step = b.step("cli", "Build and install wikidict and its invocation aliases");
    cli_step.dependOn(&cli_install.step);
    if (target.result.os.tag != .windows and target.result.os.tag != .wasi) {
        // Preserve existing CLI tooling and select the GUI via argv[0]. Both
        // aliases point at the same installed executable.
        for ([_][]const u8{ "dict", "wikidict-gio" }) |alias| {
            const link = b.addSystemCommand(&.{ "ln", "-sfn", "wikidict", alias });
            link.setCwd(b.graph.path(.install_bin, ""));
            link.has_side_effects = true;
            link.step.dependOn(&cli_install.step);
            b.getInstallStep().dependOn(&link.step);
            cli_step.dependOn(&link.step);
        }
    }

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/frontend/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "blob_encoder", .module = blob_encoder_mod },
            .{ .name = "blob_decoder", .module = blob_decoder_mod },
            .{ .name = "blob_files", .module = blob_files_mod },
            .{ .name = "blob_storage", .module = storage_mod },
            .{ .name = "unicode_lower", .module = unicode_lower_mod },
        },
    });
    const ffi_lib = b.addLibrary(.{ .name = "dictffi", .root_module = ffi_mod, .linkage = .dynamic, .use_llvm = true, .use_lld = true });
    const ffi_install = b.addInstallArtifact(ffi_lib, .{});
    const ffi_header_install = b.addInstallHeaderFile(b.path("src/ffi/dict.h"), "dict/dict.h");

    const ffi_test_mod = b.createModule(.{ .target = b.graph.host, .optimize = test_optimize, .link_libc = true });
    ffi_test_mod.addCSourceFile(.{ .file = b.path("tools/ffi_integration_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    ffi_test_mod.addIncludePath(b.path("src/ffi"));
    ffi_test_mod.linkLibrary(ffi_lib);
    const ffi_test_exe = b.addExecutable(.{ .name = "dict-ffi-integration-test", .root_module = ffi_test_mod, .use_llvm = true, .use_lld = true });

    b.getInstallStep().dependOn(&ffi_install.step);
    b.getInstallStep().dependOn(&ffi_header_install.step);
    const ffi_step = b.step("ffi", "Build and install the C FFI library and header");
    ffi_step.dependOn(&ffi_install.step);
    ffi_step.dependOn(&ffi_header_install.step);

    const module_extract_run = addRunArtifactCommand(b, module_extract_exe, &.{});
    addPublicRunStep(b, "extract-modules", "Extract Scribunto modules directly from a Wiktionary multistream dump", module_extract_run, &.{});

    const blob_verify_run = addRunArtifactCommand(b, blob_verify_exe, &.{});
    addPublicRunStep(b, "verify-blobs", "Verify compiled blob framing and presentation records", blob_verify_run, &.{});

    const blob_query_run = addRunArtifactCommand(b, blob_query_exe, &.{});
    addPublicRunStep(b, "query-blobs", "Query per-language and feature Wiktionary blobs", blob_query_run, &.{});
    addPublicRunStep(b, "dict", "Run the dictionary frontend CLI", blob_query_run, &.{});

    const test_runner = b.path("tools/test_runner.zig");
    // Compile and execute bundle_build.zig's scheduler/cache tests using the
    // same generated pipeline_paths module as the production pipeline binary.
    const bundle_pipeline_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bundle_build.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
            .imports = &.{.{ .name = "pipeline_paths", .module = pipeline_paths.createModule() }},
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const run_bundle_pipeline_tests = b.addRunArtifact(bundle_pipeline_tests);
    const run_bundle_pipeline_tests_only = b.addRunArtifact(bundle_pipeline_tests);

    const blob_build_test_options: std.Build.TestOptions = .{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/blob_build.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "encoder", .module = encoder_mod_test },
                .{ .name = "lua_parser", .module = language_metadata_parser_test_mod },
                .{ .name = "xml_decode", .module = shared_xml_decode_mod_test },
                .{ .name = "wikimedia_dump", .module = wikimedia_dump_mod },
                .{ .name = "bundle_protocol", .module = bundle_protocol_mod_test },
                .{ .name = "build_diagnostics", .module = build_diagnostics_test_mod },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    };
    const blob_build_tests = b.addTest(blob_build_test_options);
    blob_build_tests.root_module.addOptions("captured_writer_options", captured_writer_options);
    blob_build_tests.root_module.linkSystemLibrary("bz2", .{});
    blob_build_tests.root_module.linkSystemLibrary("zstd", .{});
    blob_build_tests.root_module.addImport("namespace_registry", namespace_registry_test_mod);
    const run_blob_build_tests = b.addRunArtifact(blob_build_tests);

    const blob_file_tools_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/blob_file_tools_test.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "encoder", .module = blob_encoder_mod_test },
                .{ .name = "blob_files", .module = blob_files_mod_test },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const blob_xz_test_mod = b.createModule(.{ .root_source_file = b.path("src/native/xz.zig"), .target = b.graph.host, .optimize = test_optimize });
    const blob_xz_test_lzma = b.addTranslateC(.{ .root_source_file = b.path("src/native/lzma.h"), .target = b.graph.host, .optimize = test_optimize });
    blob_xz_test_lzma.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    blob_xz_test_mod.addImport("lzma", blob_xz_test_lzma.createModule());
    blob_file_tools_tests.root_module.addImport("xz", blob_xz_test_mod);
    const run_blob_file_tools_tests = b.addRunArtifact(blob_file_tools_tests);

    const encoder_test_options: std.Build.TestOptions = .{
        .root_module = encoder_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    };
    var encoder_tests: [encoder_partitions.len]*std.Build.Step.Compile = undefined;
    for (encoder_partitions, 0..) |partition, i| {
        var options = encoder_test_options;
        options.filters = partition.filters;
        encoder_tests[i] = b.addTest(options);
    }
    const blob_encoder_tests = b.addTest(.{
        .root_module = blob_encoder_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const blob_decoder_tests = b.addTest(.{
        .root_module = blob_decoder_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const wikimedia_dump_tests = b.addTest(.{
        .root_module = wikimedia_dump_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    wikimedia_dump_tests.root_module.linkSystemLibrary("bz2", .{});
    wikimedia_dump_tests.root_module.linkSystemLibrary("zstd", .{});
    const blob_query_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontend/main.zig"),
            .target = target,
            .optimize = test_optimize,
            .imports = &.{
                .{ .name = "blob_encoder", .module = blob_encoder_mod_test },
                .{ .name = "encoder", .module = encoder_mod_test },
                .{ .name = "blob_decoder", .module = blob_decoder_mod_test },
                .{ .name = "blob_files", .module = blob_files_mod_test },
                .{ .name = "blob_storage", .module = storage_test },
                .{ .name = "unicode_lower", .module = unicode_lower_test_mod },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    blob_query_tests.root_module.link_libc = true;
    blob_query_tests.use_llvm = true;
    blob_query_tests.use_lld = true;
    const lua_test_options: std.Build.TestOptions = .{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua/tests.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "xml_decode", .module = shared_xml_decode_mod_test },
                .{ .name = "wikimedia_dump", .module = wikimedia_dump_mod_test },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    };
    const lua_tests = b.addTest(lua_test_options);
    lua_tests.root_module.addImport("namespace_registry", namespace_registry_test_mod);
    lua_tests.root_module.addImport("missing_dependency", missing_dependency_test_mod);
    lua_tests.root_module.linkSystemLibrary("LLVM", .{ .use_pkg_config = .no });
    lua_tests.root_module.linkSystemLibrary("bz2", .{});
    lua_tests.root_module.linkSystemLibrary("zstd", .{});
    const lua_static_fields_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/abi/static_fields.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const lua_globals_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/abi/globals.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const lua_wikitext_preprocess_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/wikitext/preprocess.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const lua_wikitext_expression_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/wikitext/expression.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    lua_wikitext_preprocess_test_mod.addImport("missing_dependency", missing_dependency_test_mod);
    const zig_runtime_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/runtime/core.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
    });
    zig_runtime_test_mod.addImport("namespace_registry", namespace_registry_test_mod);
    zig_runtime_test_mod.addImport("missing_dependency", missing_dependency_test_mod);
    zig_runtime_test_mod.addImport("lua_static_fields", lua_static_fields_test_mod);
    const value_leaf_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/value_leaf_build.zig"),
        .target = target,
        .optimize = .fast,
        // Match the stripped production leaf bitcode producer. Debug metadata
        // is not part of the runtime ABI and can exceed its bounded input size.
        .strip = true,
        .link_libc = true,
        .imports = &.{.{ .name = "zig_runtime", .module = zig_runtime_test_mod }},
    });
    const value_leaf_test_obj = b.addObject(.{
        .name = "dict-lua-value-leaf-test",
        .root_module = value_leaf_test_mod,
    });
    value_leaf_test_obj.use_llvm = true;
    const value_leaf_test_bc = value_leaf_test_obj.getEmittedLlvmBc();
    const lua_core_test_options: std.Build.TestOptions = .{
        .root_module = zig_runtime_test_mod,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    };
    const lua_core_tests = b.addTest(lua_core_test_options);
    const lua_core_tests_standalone = b.addTest(lua_core_test_options);
    const global_index_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/runtime/global_shape_index.zig"),
        .target = target,
        .optimize = test_optimize,
        .imports = &.{.{ .name = "lua_globals", .module = lua_globals_test_mod }},
    });
    const global_index_tests = b.addTest(.{
        .root_module = global_index_test_mod,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const global_index_tests_standalone = b.addTest(.{
        .root_module = global_index_test_mod,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const program_metadata_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/program_metadata.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const program_shapes_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/runtime/program_shapes.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zig_runtime", .module = zig_runtime_test_mod },
            .{ .name = "lua_program_metadata", .module = program_metadata_test_mod },
        },
    });
    const program_shapes_tests = b.addTest(.{
        .root_module = program_shapes_test_mod,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const run_program_shapes_tests = b.addRunArtifact(program_shapes_tests);
    const static_literal_format_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/runtime/static_literal_format.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const static_literal_decode_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/runtime/static_literal_decode.zig"),
        .target = target,
        .optimize = test_optimize,
        .imports = &.{
            .{ .name = "zig_runtime", .module = zig_runtime_test_mod },
            .{ .name = "lua_static_literal_format", .module = static_literal_format_test_mod },
        },
    });
    const lua_abi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/runtime/llvm_abi.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zig_runtime", .module = zig_runtime_test_mod },
            .{ .name = "lua_static_literal_decode", .module = static_literal_decode_test_mod },
            .{ .name = "lua_static_literal_format", .module = static_literal_format_test_mod },
        },
    });
    const lua_abi_test_options: std.Build.TestOptions = .{
        .root_module = lua_abi_test_mod,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    };
    const lua_abi_tests = b.addTest(lua_abi_test_options);
    const lua_abi_tests_standalone = b.addTest(lua_abi_test_options);
    const lua_stdlib_test_options: std.Build.TestOptions = .{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua/runtime/stdlib.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zig_runtime", .module = zig_runtime_test_mod },
                .{ .name = "lua_globals", .module = lua_globals_test_mod },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    };
    const lua_stdlib_tests = b.addTest(lua_stdlib_test_options);
    const lua_ustring_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua/runtime/ustring.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zig_runtime", .module = zig_runtime_test_mod }},
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const lua_scribunto_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua/runtime/scribunto.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zig_runtime", .module = zig_runtime_test_mod },
                .{ .name = "zig_stdlib", .module = lua_stdlib_tests.root_module },
                .{ .name = "lua_globals", .module = lua_globals_test_mod },
                .{ .name = "lua_wikitext_preprocess", .module = lua_wikitext_preprocess_test_mod },
                .{ .name = "lua_wikitext_expression", .module = lua_wikitext_expression_test_mod },
                .{ .name = "shared_xml_decode", .module = shared_xml_decode_mod_test },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    lua_scribunto_tests.root_module.addImport("missing_dependency", missing_dependency_test_mod);
    const lua_wikitext_test_options: std.Build.TestOptions = .{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua/runtime/wikitext.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zig_runtime", .module = zig_runtime_test_mod },
                .{ .name = "zig_stdlib", .module = lua_stdlib_tests.root_module },
                .{ .name = "lua_wikitext_preprocess", .module = lua_wikitext_preprocess_test_mod },
                .{ .name = "lua_wikitext_expression", .module = lua_wikitext_expression_test_mod },
                .{ .name = "shared_xml_decode", .module = shared_xml_decode_mod_test },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    };
    const lua_wikitext_tests = b.addTest(lua_wikitext_test_options);
    lua_wikitext_tests.root_module.addImport("missing_dependency", missing_dependency_test_mod);
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
    var run_encoder_tests: [encoder_partitions.len]*std.Build.Step.Run = undefined;
    for (encoder_partitions, 0..) |partition, i| {
        const run = b.addRunArtifact(encoder_tests[i]);
        if (partition.runtime_filter) |filter| run.addArgs(&.{ "--test-filter", filter });
        // Serialize compilation as well as execution. Each next compiler waits
        // for the preceding partition's tests, not merely its compilation.
        if (i != 0) encoder_tests[i].step.dependOn(&run_encoder_tests[i - 1].step);
        run_encoder_tests[i] = run;
    }
    const run_blob_encoder_tests = b.addRunArtifact(blob_encoder_tests);
    const run_blob_decoder_tests = b.addRunArtifact(blob_decoder_tests);
    const run_blob_query_tests = b.addRunArtifact(blob_query_tests);
    const run_wikimedia_dump_tests = b.addRunArtifact(wikimedia_dump_tests);
    const run_lua_tests = b.addRunArtifact(lua_tests);
    const run_lua_core_tests = b.addRunArtifact(lua_core_tests);
    const run_lua_core_tests_only = b.addRunArtifact(lua_core_tests_standalone);
    const run_global_index_tests = b.addRunArtifact(global_index_tests);
    const run_global_index_tests_only = b.addRunArtifact(global_index_tests_standalone);
    const run_lua_abi_tests = b.addRunArtifact(lua_abi_tests);
    const run_lua_abi_tests_only = b.addRunArtifact(lua_abi_tests_standalone);
    const run_lua_stdlib_tests = b.addRunArtifact(lua_stdlib_tests);
    const run_lua_ustring_tests = b.addRunArtifact(lua_ustring_tests);
    const run_lua_scribunto_tests = b.addRunArtifact(lua_scribunto_tests);
    const run_lua_wikitext_tests = b.addRunArtifact(lua_wikitext_tests);

    blob_encoder_tests.step.dependOn(&run_encoder_tests[encoder_partitions.len - 1].step);
    blob_decoder_tests.step.dependOn(&run_blob_encoder_tests.step);
    blob_query_tests.step.dependOn(&run_blob_decoder_tests.step);
    wikimedia_dump_tests.step.dependOn(&run_blob_query_tests.step);
    lua_tests.step.dependOn(&run_wikimedia_dump_tests.step);
    lua_core_tests.step.dependOn(&run_lua_tests.step);
    global_index_tests.step.dependOn(&run_lua_core_tests.step);
    program_shapes_tests.step.dependOn(&run_global_index_tests.step);
    lua_abi_tests.step.dependOn(&run_program_shapes_tests.step);
    lua_stdlib_tests.step.dependOn(&run_lua_abi_tests.step);
    lua_ustring_tests.step.dependOn(&run_lua_stdlib_tests.step);
    lua_scribunto_tests.step.dependOn(&run_lua_ustring_tests.step);
    lua_wikitext_tests.step.dependOn(&run_lua_scribunto_tests.step);
    const bundle_protocol_tests = b.addTest(.{
        .root_module = bundle_protocol_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const run_bundle_protocol_tests = b.addRunArtifact(bundle_protocol_tests);
    run_bundle_protocol_tests.step.dependOn(&run_lua_wikitext_tests.step);

    const namespace_registry_tests = b.addTest(.{ .root_module = namespace_registry_test_mod, .test_runner = .{ .path = test_runner, .mode = .simple } });
    const run_namespace_registry_tests = b.addRunArtifact(namespace_registry_tests);
    b.step("test-namespace-registry", "Validate edition namespace and title resolution").dependOn(&run_namespace_registry_tests.step);
    lua_tests.step.dependOn(&run_namespace_registry_tests.step);
    const program_provider_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/runtime/llvm_program.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zig_runtime", .module = zig_runtime_test_mod },
            .{ .name = "zig_stdlib", .module = lua_stdlib_tests.root_module },
            .{ .name = "zig_scribunto", .module = lua_scribunto_tests.root_module },
            .{ .name = "lua_globals", .module = lua_globals_test_mod },
            .{ .name = "lua_program_metadata", .module = program_metadata_test_mod },
            .{ .name = "lua_static_literal_decode", .module = static_literal_decode_test_mod },
        },
    });
    const provider_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/lua/bundle_pages.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "lua_program", .module = program_provider_test_mod },
            .{ .name = "shared_xml_decode", .module = shared_xml_decode_mod_test },
            .{ .name = "lua_wikitext_preprocess", .module = lua_wikitext_preprocess_test_mod },
            .{ .name = "wikimedia_dump", .module = wikimedia_dump_mod_test },
        },
    }), .test_runner = .{ .path = test_runner, .mode = .simple } });
    provider_tests.root_module.linkSystemLibrary("bz2", .{});
    provider_tests.root_module.linkSystemLibrary("zstd", .{});
    const run_provider_tests = b.addRunArtifact(provider_tests);
    b.step("test-bundle-pages", "Test source provider and namespace identities").dependOn(&run_provider_tests.step);
    const closure_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/lua/extract/usage_closure.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "namespace_registry", .module = namespace_registry_mod },
            .{ .name = "lua_usage", .module = lua_usage_mod },
            .{ .name = "xml_decode", .module = shared_xml_decode_mod },
            .{ .name = "wikimedia_dump", .module = wikimedia_dump_mod },
        },
    }), .test_runner = .{ .path = test_runner, .mode = .simple } });
    closure_tests.root_module.linkSystemLibrary("bz2", .{});
    closure_tests.root_module.linkSystemLibrary("zstd", .{});
    const run_closure_tests = b.addRunArtifact(closure_tests);
    b.step("test-usage-closure", "Test sparse cross-namespace transclusion closure").dependOn(&run_closure_tests.step);
    const test_step = b.step("test", "Run bundle encoder, data reader, Lua, and tooling tests");
    const missing_dependency_tests = b.addTest(.{ .root_module = missing_dependency_test_mod, .test_runner = .{ .path = test_runner, .mode = .simple } });
    const run_missing_dependency_tests = b.addRunArtifact(missing_dependency_tests);
    test_step.dependOn(&run_missing_dependency_tests.step);
    b.step("test-lua-core", "Run Lua runtime core tests serially").dependOn(&run_lua_core_tests_only.step);
    b.step("test-global-index", "Run Lua global-name index tests serially").dependOn(&run_global_index_tests_only.step);
    b.step("test-lua-abi", "Run Lua LLVM ABI tests serially").dependOn(&run_lua_abi_tests_only.step);
    blob_wasm_smoke.step.dependOn(&run_bundle_protocol_tests.step);
    run_bundle_pipeline_tests.step.dependOn(&blob_wasm_smoke.step);
    run_blob_build_tests.step.dependOn(&run_bundle_pipeline_tests.step);
    test_step.dependOn(&run_blob_build_tests.step);
    run_blob_file_tools_tests.step.dependOn(&run_blob_build_tests.step);
    test_step.dependOn(&run_blob_file_tools_tests.step);
    test_step.dependOn(&run_closure_tests.step);
    test_step.dependOn(&run_provider_tests.step);
    b.step("test-bundle-pipeline", "Run bundle build scheduler and cache bitmap unit tests only").dependOn(&run_bundle_pipeline_tests_only.step);
    const media_fetch_exe = addCliExecutable(b, "dict-media-fetch", b.path("tools/media_fetch.zig"), target, optimize, &.{ .{ .name = "media_types", .module = b.createModule(.{ .root_source_file = b.path("src/frontend/media_types.zig"), .target = target, .optimize = optimize }) }, .{ .name = "shared_xml_decode", .module = shared_xml_decode_mod } });
    addPublicRunStep(b, "fetch-media", "Download bounded attributed Wikimedia assets for an export", addRunArtifactCommand(b, media_fetch_exe, &.{}), &.{});
    const bundle_test_exe = addCliExecutable(b, "dict-bundle-integration-test", b.path("tools/bundle_integration_test.zig"), b.graph.host, test_optimize, &.{ .{ .name = "bundle_protocol", .module = bundle_protocol_mod_test }, .{ .name = "namespace_registry", .module = namespace_registry_test_mod } });
    bundle_test_exe.root_module.addImport("build_diagnostics", build_diagnostics_test_mod);
    bundle_test_exe.root_module.addImport("encoder", encoder_mod_test);
    bundle_test_exe.root_module.addImport("wikimedia_dump", wikimedia_dump_mod_test);
    const bundle_test_run = b.addRunArtifact(bundle_test_exe);
    bundle_test_run.addFileArg(blob_query_exe.getEmittedBin());
    bundle_test_run.addFileArg(pipeline_exe.getEmittedBin());
    bundle_test_run.addFileArg(blob_verify_exe.getEmittedBin());
    bundle_test_run.setCwd(b.path("."));
    bundle_test_run.addDirectoryArg2(std.Build.LazyPath.cache_root, .{ .make_absolute = true });
    bundle_test_run.addFileArg(llvm_exe.getEmittedBin());
    bundle_test_run.addFileArg(blob_build_exe.getEmittedBin());
    bundle_test_run.addFileArg(value_leaf_test_bc);
    bundle_test_run.addFileArg(module_extract_exe.getEmittedBin());
    b.step("test-bundle", "Exercise build-time Lua/template expansion into data-only blobs").dependOn(&bundle_test_run.step);
    const reader_test_exe = addCliExecutable(b, "dict-reader-integration-test", b.path("tools/reader_integration_test.zig"), b.graph.host, test_optimize, &.{.{ .name = "blob_encoder", .module = blob_encoder_mod_test }});
    reader_test_exe.root_module.addImport("encoder", encoder_mod_test);
    const reader_test_run = b.addRunArtifact(reader_test_exe);
    reader_test_run.addFileArg(blob_query_exe.getEmittedBin());
    reader_test_run.addFileArg(ffi_test_exe.getEmittedBin());
    reader_test_run.setCwd(b.path("."));
    reader_test_run.addDirectoryArg2(std.Build.LazyPath.cache_root, .{ .make_absolute = true });
    b.step("test-reader", "Exercise precompiled data-only reading through CLI and C FFI").dependOn(&reader_test_run.step);
    const index_blobs_exe = addCliExecutable(b, "dict-index-blobs", b.path("tools/index_blobs.zig"), target, optimize, &.{.{ .name = "blob_storage", .module = storage_mod }});
    index_blobs_exe.root_module.link_libc = true;
    index_blobs_exe.use_llvm = true;
    index_blobs_exe.use_lld = true;
    addPublicRunStep(b, "index-blobs", "Build or reuse external raw/XZ record indexes after compression", addRunArtifactCommand(b, index_blobs_exe, &.{}), &.{});
    const storage_exe = addCliExecutable(b, "dict-storage-integration-test", b.path("tools/storage_integration_test.zig"), target, test_optimize, &.{ .{ .name = "blob_encoder", .module = blob_encoder_mod_test }, .{ .name = "blob_storage", .module = storage_test } });
    storage_exe.root_module.link_libc = true;
    storage_exe.use_llvm = true;
    storage_exe.use_lld = true;
    const storage_run = b.addRunArtifact(storage_exe);
    storage_run.setCwd(b.path("."));
    storage_run.addDirectoryArg2(std.Build.LazyPath.cache_root, .{ .make_absolute = true });
    const storage_unit = b.addTest(.{ .root_module = storage_test, .test_runner = .{ .path = test_runner, .mode = .simple } });
    storage_unit.root_module.link_libc = true;
    storage_unit.use_llvm = true;
    storage_unit.use_lld = true;
    const storage_unit_run = b.addRunArtifact(storage_unit);
    storage_unit_run.step.dependOn(&reader_test_run.step);
    storage_run.step.dependOn(&storage_unit_run.step);
    b.step("test-storage", "Exercise after-compression indexes and selective real XZ block decoding").dependOn(&storage_run.step);
    if (target.result.os.tag == b.graph.host.result.os.tag and target.result.cpu.arch == b.graph.host.result.cpu.arch) test_step.dependOn(&storage_run.step);

    // Only prepared artifacts use these filters. The public full test graph
    // above remains unfiltered, including when these options are supplied.
    const prepare_group = b.option(PreparedTestGroup, "prepare-test-group", "Compile only this prepare-tests group");
    const requested_filters = b.option([]const []const u8, "prepare-test-filter", "Repeat to compile named tests in the selected prepare-tests group") orelse &.{};
    const prepare_error_tracing = b.option(bool, "prepare-test-error-tracing", "Enable error-return traces for selected prepared test roots") orelse false;
    const prepare_filters = preparedTestFilters(b.allocator, prepare_group, requested_filters) catch |err| {
        std.log.err("invalid prepare-tests selection: {s}", .{@errorName(err)});
        b.invalid_user_input = true;
        return;
    };
    const prepared_tests = [_]struct { group: PreparedTestGroup, artifact: *std.Build.Step.Compile }{
        .{ .group = .encoder_compile, .artifact = encoder_tests[0] },
        .{ .group = .encoder_document, .artifact = encoder_tests[1] },
        .{ .group = .encoder_writer, .artifact = encoder_tests[2] },
        .{ .group = .encoder_support, .artifact = encoder_tests[3] },
        .{ .group = .lua, .artifact = lua_tests },
        .{ .group = .lua_core, .artifact = lua_core_tests },
        .{ .group = .lua_abi, .artifact = lua_abi_tests },
        .{ .group = .lua_stdlib, .artifact = lua_stdlib_tests },
        .{ .group = .lua_wikitext, .artifact = lua_wikitext_tests },
        .{ .group = .tools, .artifact = blob_build_tests },
        .{ .group = .closure, .artifact = closure_tests },
        .{ .group = .provider, .artifact = provider_tests },
        .{ .group = .storage_unit, .artifact = storage_unit },
        .{ .group = .namespace_registry, .artifact = namespace_registry_tests },
        .{ .group = .blob_encoder, .artifact = blob_encoder_tests },
        .{ .group = .blob_decoder, .artifact = blob_decoder_tests },
        .{ .group = .blob_query, .artifact = blob_query_tests },
        .{ .group = .wikimedia_dump, .artifact = wikimedia_dump_tests },
        .{ .group = .global_index, .artifact = global_index_tests },
        .{ .group = .program_shapes, .artifact = program_shapes_tests },
        .{ .group = .lua_ustring, .artifact = lua_ustring_tests },
        .{ .group = .lua_scribunto, .artifact = lua_scribunto_tests },
        .{ .group = .bundle_protocol, .artifact = bundle_protocol_tests },
        .{ .group = .bundle_pipeline, .artifact = bundle_pipeline_tests },
        .{ .group = .blob_file_tools, .artifact = blob_file_tools_tests },
        .{ .group = .missing_dependency, .artifact = missing_dependency_tests },
    };
    const prepare_tests = b.step("prepare-tests", "Compile test executables for runtime-filtered qualification");
    // The normal pipeline group also requires the reader's freestanding smoke
    // compilation. Clone only that object, not its serial protocol-test run.
    if (prepare_group == .bundle_pipeline) {
        const smoke = b.addObject(.{
            .name = blob_wasm_smoke.name,
            .root_module = blob_wasm_smoke.root_module,
            .max_rss = blob_wasm_smoke.step.max_rss,
            .use_llvm = blob_wasm_smoke.use_llvm,
            .use_lld = blob_wasm_smoke.use_lld,
            .zig_lib_dir = blob_wasm_smoke.zig_lib_dir,
        });
        prepare_tests.dependOn(&smoke.step);
    }
    // Preserve existing explicitly filtered invocations. Empty filters always
    // use the four normal partitions; there is no unfiltered encoder fallback.
    if (prepare_group == .encoder and prepare_filters.len != 0) {
        var options = preparedTestOptions(encoder_tests[0], prepare_filters);
        options.root_module = preparedRoot(b, options.root_module, prepare_error_tracing);
        const install = b.addInstallArtifact(b.addTest(options), .{ .dest_sub_path = "wikidict-tests/encoder" });
        prepare_tests.dependOn(&install.step);
        return;
    }
    var previous_prepared_encoder: ?*std.Build.Step = null;
    for (prepared_tests) |prepared| {
        if (!preparedTestGroupIncluded(prepare_group, prepared.group)) continue;
        var options = preparedTestOptions(prepared.artifact, prepare_filters);
        options.root_module = preparedRoot(b, options.root_module, prepare_error_tracing);
        const compiled = b.addTest(options);
        if (isEncoderPartition(prepared.group)) {
            if (previous_prepared_encoder) |previous| compiled.step.dependOn(previous);
        }
        const install = b.addInstallArtifact(compiled, .{
            .dest_sub_path = b.fmt("wikidict-tests/{s}", .{@tagName(prepared.group)}),
        });
        if (isEncoderPartition(prepared.group)) previous_prepared_encoder = &install.step;
        prepare_tests.dependOn(&install.step);
    }
}

fn bundleValueLeafObject(b: *std.Build) *std.Build.Step.Compile {
    // Match build-obj -Ofast -mcpu=baseline -fllvm -fstrip -lc. This graph is
    // separate from the native-CPU worker graph so its imports also retain
    // baseline CPU features and the build_value_leaf root's extern TLS mode.
    const target = b.resolveTargetQuery(.{ .cpu_model = .baseline });
    const namespace = namespaceRegistryModule(b, target, .fast);
    const fields = b.createModule(.{
        .root_source_file = b.path("src/lua/abi/static_fields.zig"),
        .target = target,
        .optimize = .fast,
    });
    const runtime = b.createModule(.{
        .root_source_file = b.path("src/lua/runtime/core.zig"),
        .target = target,
        .optimize = .fast,
        .imports = &.{
            .{ .name = "lua_static_fields", .module = fields },
            .{ .name = "namespace_registry", .module = namespace },
        },
    });
    runtime.addImport("missing_dependency", b.createModule(.{ .root_source_file = b.path("src/shared/missing_dependency.zig"), .target = target, .optimize = .fast }));
    return b.addObject(.{
        .name = "value_leaf_build",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua/value_leaf_build.zig"),
            .target = target,
            .optimize = .fast,
            .strip = true,
            .link_libc = true,
            .imports = &.{.{ .name = "zig_runtime", .module = runtime }},
        }),
        .use_llvm = true,
    });
}

// The worker contains repository runtime code only; generated Lua objects and
// per-edition metadata join it at the existing native link step. Keep this
// graph independent of caller target/optimization and of safe test modules.
fn bundleWorkerObject(b: *std.Build) *std.Build.Step.Compile {
    const namespace = namespaceRegistryModule(b, b.graph.host, .fast);
    const fields = workerModule(b, "src/lua/abi/static_fields.zig");
    const globals = workerModule(b, "src/lua/abi/globals.zig");
    const metadata = workerModule(b, "src/lua/program_metadata.zig");
    const static_format = workerModule(b, "src/lua/runtime/static_literal_format.zig");
    const preprocess = workerModule(b, "src/lua/wikitext/preprocess.zig");
    const expression = workerModule(b, "src/lua/wikitext/expression.zig");
    const xml = workerModule(b, "src/shared/xml_decode.zig");
    const dump = workerModule(b, "src/shared/wikimedia_dump.zig");
    const missing_dependency = workerModule(b, "src/shared/missing_dependency.zig");
    preprocess.addImport("missing_dependency", missing_dependency);
    const runtime = workerModule(b, "src/lua/runtime/core.zig");
    runtime.addImport("lua_static_fields", fields);
    runtime.addImport("namespace_registry", namespace);
    runtime.addImport("missing_dependency", missing_dependency);
    const static_decode = workerModule(b, "src/lua/runtime/static_literal_decode.zig");
    static_decode.addImport("zig_runtime", runtime);
    static_decode.addImport("lua_static_literal_format", static_format);
    const stdlib = workerModule(b, "src/lua/runtime/stdlib.zig");
    stdlib.addImport("zig_runtime", runtime);
    stdlib.addImport("lua_globals", globals);
    const scribunto = workerModule(b, "src/lua/runtime/scribunto.zig");
    scribunto.addImport("zig_runtime", runtime);
    scribunto.addImport("zig_stdlib", stdlib);
    scribunto.addImport("lua_wikitext_preprocess", preprocess);
    scribunto.addImport("lua_wikitext_expression", expression);
    scribunto.addImport("shared_xml_decode", xml);
    scribunto.addImport("missing_dependency", missing_dependency);
    const program = workerModule(b, "src/lua/runtime/llvm_program.zig");
    program.addImport("zig_runtime", runtime);
    program.addImport("zig_stdlib", stdlib);
    program.addImport("zig_scribunto", scribunto);
    program.addImport("lua_globals", globals);
    program.addImport("lua_program_metadata", metadata);
    program.addImport("lua_static_literal_decode", static_decode);
    const abi = workerModule(b, "src/lua/runtime/llvm_abi.zig");
    abi.addImport("zig_runtime", runtime);
    abi.addImport("lua_static_literal_decode", static_decode);
    abi.addImport("lua_static_literal_format", static_format);
    const root = workerModule(b, "src/lua/bundle_worker.zig");
    root.link_libc = true;
    root.addImport("lua_program", program);
    root.addImport("lua_llvm_abi", abi);
    root.addImport("shared_xml_decode", xml);
    root.addImport("lua_wikitext_preprocess", preprocess);
    root.addImport("wikimedia_dump", dump);
    root.addImport("missing_dependency", missing_dependency);
    return b.addObject(.{
        .name = "dict-bundle-runtime",
        .root_module = root,
        .use_llvm = true,
    });
}

fn workerModule(b: *std.Build, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = b.graph.host,
        .optimize = .fast,
    });
}

fn addCliExecutable(
    b: *std.Build,
    name: []const u8,
    root_source: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
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
) *std.Build.Step.Run {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path("."));
    for (fixed_args) |arg| run_cmd.addArg(arg);
    run_cmd.addPassthruArgs();
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

fn namespaceRegistryModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Module {
    const unicode = b.createModule(.{ .root_source_file = b.path("src/frontend/unicode_lower.zig"), .target = target, .optimize = optimize });
    return b.createModule(.{ .root_source_file = b.path("src/shared/namespace_registry_module.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "unicode_lower", .module = unicode }} });
}

const PreparedTestGroup = enum {
    encoder, encoder_compile, encoder_document, encoder_writer, encoder_support, lua, lua_core, lua_abi, lua_stdlib, lua_wikitext, tools, closure, provider, storage_unit, namespace_registry, blob_encoder, blob_decoder, blob_query, wikimedia_dump, global_index, program_shapes, lua_ustring, lua_scribunto, bundle_protocol, bundle_pipeline, blob_file_tools, missing_dependency
};

const encoder_discovery_filter = "encoder root imports bundle-time presentation modules";
const EncoderPartition = struct {
    group: PreparedTestGroup,
    filters: []const []const u8,
    runtime_filter: ?[]const u8,
};
// Keep the existing source root and qualified names. Discovery is compiled in
// every artifact, but only support executes it. Match the complete inventory
// when changing these boundaries; test-filter is substring-based.
const encoder_partitions = [_]EncoderPartition{
    .{ .group = .encoder_compile, .filters = &.{ "presentation_compile.test.", encoder_discovery_filter }, .runtime_filter = "presentation_compile.test." },
    .{ .group = .encoder_document, .filters = &.{ "presentation_document.test.", encoder_discovery_filter }, .runtime_filter = "presentation_document.test." },
    .{ .group = .encoder_writer, .filters = &.{ "blob_builder.test.", encoder_discovery_filter }, .runtime_filter = "blob_builder.test." },
    .{ .group = .encoder_support, .filters = &.{
        "font_scale.test.", "hieroglyph_unicode.test.", "language_source.test.",
        "presentation_citations.test.", "presentation_heading_anchors.test.",
        "presentation_layout.test.", "presentation_media.test.",
        "redirect_source.test.", "root.test.", "table_style_profile.test.",
    }, .runtime_filter = null },
};

fn isEncoderPartition(group: PreparedTestGroup) bool {
    return switch (group) {
        .encoder_compile, .encoder_document, .encoder_writer, .encoder_support => true,
        else => false,
    };
}

fn preparedRoot(b: *std.Build, original: *std.Build.Module, tracing: bool) *std.Build.Module {
    if (!tracing) return original;
    // Preserve every root setting/import, changing only this prepared compile.
    const traced = b.allocator.create(std.Build.Module) catch @panic("OOM");
    traced.init(b, .{ .existing = original });
    traced.error_tracing = true;
    return traced;
}

fn preparedTestGroupIncluded(selected: ?PreparedTestGroup, group: PreparedTestGroup) bool {
    if (selected) |wanted| {
        if (wanted == .encoder) return isEncoderPartition(group);
        return wanted == group;
    }
    // Seven logical suites, with encoder represented by four physical artifacts.
    // Other normal roots remain opt-in, never implicit suite completion.
    return switch (group) {
        .encoder_compile, .encoder_document, .encoder_writer, .encoder_support,
        .lua, .lua_core, .lua_abi, .lua_stdlib, .lua_wikitext, .tools => true,
        else => false,
    };
}

// Reuse the normal root's modules and backend choices, without copying its
// serial run dependencies. Each selected root is a fresh compile-only step.
fn preparedTestOptions(original: *std.Build.Step.Compile, filters: []const []const u8) std.Build.TestOptions {
    std.debug.assert(original.kind == .@"test");
    return .{
        .name = original.name,
        .root_module = original.root_module,
        .max_rss = original.step.max_rss,
        .filters = if (filters.len == 0) original.filters else filters,
        .test_runner = original.test_runner,
        .use_llvm = original.use_llvm,
        .use_lld = original.use_lld,
        .zig_lib_dir = original.zig_lib_dir,
    };
}

fn preparedTestFilters(a: std.mem.Allocator, group: ?PreparedTestGroup, requested: []const []const u8) ![]const []const u8 {
    if (requested.len == 0) return &.{};
    const selected = group orelse return error.PrepareTestGroupRequired;
    for (requested) |filter| if (filter.len == 0) return error.EmptyTestFilter;
    // Zig's filters are ORed substrings, not an intersection with a partition.
    // Explicit focused filters continue to use -Dprepare-test-group=encoder.
    if (isEncoderPartition(selected)) return error.EncoderPartitionFilterNotSupported;
    var filters: std.ArrayList([]const u8) = .empty;
    errdefer filters.deinit(a);
    try filters.appendSlice(a, requested);
    // Filtering out these import-only tests also hides tests in their imported
    // source files. Keep discovery compiled; the caller still runs exact names.
    const discovery: ?[]const u8 = switch (selected) {
        .encoder => "encoder root imports bundle-time presentation modules",
        .lua => "tests.test_0",
        else => null,
    };
    if (discovery) |name| {
        var present = false;
        for (requested) |filter| {
            if (std.mem.eql(u8, filter, name)) {
                present = true;
                break;
            }
        }
        if (!present) try filters.append(a, name);
    }
    return filters.toOwnedSlice(a);
}

test "prepared test default retains seven logical suites with four encoder artifacts" {
    var count: usize = 0;
    for (std.meta.tags(PreparedTestGroup)) |group| {
        if (preparedTestGroupIncluded(null, group)) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), count);
    for ([_]PreparedTestGroup{ .encoder_compile, .encoder_document, .encoder_writer, .encoder_support, .lua, .lua_core, .lua_abi, .lua_stdlib, .lua_wikitext, .tools }) |group| {
        try std.testing.expect(preparedTestGroupIncluded(null, group));
    }
    try std.testing.expect(!preparedTestGroupIncluded(null, .blob_encoder));
    try std.testing.expect(!preparedTestGroupIncluded(null, .blob_file_tools));
    try std.testing.expectEqual(@as(usize, 0), (try preparedTestFilters(std.testing.allocator, null, &.{})).len);
}

test "prepared test selection excludes unrelated groups" {
    for (std.meta.tags(PreparedTestGroup)) |group| {
        try std.testing.expectEqual(isEncoderPartition(group), preparedTestGroupIncluded(.encoder, group));
    }
    for (std.meta.tags(PreparedTestGroup)) |group| {
        try std.testing.expectEqual(group == .blob_encoder, preparedTestGroupIncluded(.blob_encoder, group));
    }
    try std.testing.expectError(error.PrepareTestGroupRequired, preparedTestFilters(std.testing.allocator, null, &.{"one"}));
    try std.testing.expectError(error.EmptyTestFilter, preparedTestFilters(std.testing.allocator, .encoder, &.{""}));
}

test "prepared test filters retain encoder and Lua import discovery" {
    const encoder = try preparedTestFilters(std.testing.allocator, .encoder, &.{"one", "two"});
    defer std.testing.allocator.free(encoder);
    try std.testing.expectEqual(@as(usize, 3), encoder.len);
    try std.testing.expectEqualStrings("one", encoder[0]);
    try std.testing.expectEqualStrings("two", encoder[1]);
    try std.testing.expectEqualStrings("encoder root imports bundle-time presentation modules", encoder[2]);
    const lua = try preparedTestFilters(std.testing.allocator, .lua, &.{"one"});
    defer std.testing.allocator.free(lua);
    try std.testing.expectEqualStrings("tests.test_0", lua[1]);
}

test "prepared test direct roots keep only requested filters" {
    const core = try preparedTestFilters(std.testing.allocator, .lua_core, &.{"one"});
    defer std.testing.allocator.free(core);
    try std.testing.expectEqual(@as(usize, 1), core.len);
    const encoder = try preparedTestFilters(std.testing.allocator, .encoder, &.{"encoder root imports bundle-time presentation modules"});
    defer std.testing.allocator.free(encoder);
    try std.testing.expectEqual(@as(usize, 1), encoder.len);
}

test "prepared test options preserve normal modules backend runner and limits" {
    var module: std.Build.Module = undefined;
    var original: std.Build.Step.Compile = undefined;
    original.kind = .@"test";
    original.name = "test";
    original.root_module = &module;
    original.step.max_rss = 321;
    original.filters = &.{};
    original.test_runner = .{ .path = .{ .cwd_relative = "tools/test_runner.zig" }, .mode = .simple };
    original.use_llvm = true;
    original.use_lld = true;
    original.zig_lib_dir = .{ .cwd_relative = "zig-lib" };
    const options = preparedTestOptions(&original, &.{"one"});
    try std.testing.expect(options.root_module == &module);
    try std.testing.expectEqualStrings("test", options.name);
    try std.testing.expectEqual(@as(u64, 321), options.max_rss);
    try std.testing.expectEqual(@as(?bool, true), options.use_llvm);
    try std.testing.expectEqual(@as(?bool, true), options.use_lld);
    try std.testing.expectEqualStrings("tools/test_runner.zig", options.test_runner.?.path.cwd_relative);
    try std.testing.expect(options.test_runner.?.mode == .simple);
    try std.testing.expectEqualStrings("zig-lib", options.zig_lib_dir.?.cwd_relative);
    try std.testing.expectEqualStrings("one", options.filters[0]);
}


test "encoder partitions retain discovery and select disjoint module tests" {
    const cases = [_]struct { name: []const u8, group: PreparedTestGroup }{
        .{ .name = "presentation_compile.test.same", .group = .encoder_compile },
        .{ .name = "presentation_compile.test.same with suffix", .group = .encoder_compile },
        .{ .name = "presentation_document.test.same", .group = .encoder_document },
        .{ .name = "blob_builder.test.same", .group = .encoder_writer },
        .{ .name = "presentation_layout.test.same", .group = .encoder_support },
        .{ .name = "root.test.encoder root imports bundle-time presentation modules", .group = .encoder_support },
    };
    for (cases) |case| {
        var executions: usize = 0;
        for (encoder_partitions) |partition| {
            var compiled = false;
            for (partition.filters) |filter| compiled = compiled or std.mem.indexOf(u8, case.name, filter) != null;
            const selected = compiled and (if (partition.runtime_filter) |filter| std.mem.indexOf(u8, case.name, filter) != null else true);
            if (selected) {
                executions += 1;
                try std.testing.expectEqual(case.group, partition.group);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), executions);
    }
    for (encoder_partitions) |partition| {
        var discovered = false;
        for (partition.filters) |filter| discovered = discovered or std.mem.indexOf(u8, "root.test.encoder root imports bundle-time presentation modules", filter) != null;
        try std.testing.expect(discovered);
        try std.testing.expect(preparedTestGroupIncluded(.encoder, partition.group));
        try std.testing.expect(preparedTestGroupIncluded(partition.group, partition.group));
        try std.testing.expectError(error.EncoderPartitionFilterNotSupported, preparedTestFilters(std.testing.allocator, partition.group, &.{"same"}));
    }
}
