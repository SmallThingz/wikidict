const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step_memory = b.option(u64, "test-step-max-rss", "Opt-in RSS reservation per compile/run/translate step; pair with --maxrss") orelse 0;
    validateQualificationStepMemory(test_step_memory) catch |err| {
        std.log.err("invalid test step memory reservation: {s}", .{@errorName(err)});
        b.invalid_user_input = true;
        return;
    };
    // Run after all graph construction, including every prepared early return.
    defer if (!b.invalid_user_input) claimQualificationMemory(b, test_step_memory);
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.Optimize,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .safe;
    const test_optimize: std.builtin.Optimize = switch (b.option(
        enum { safe, debug },
        "test-optimize",
        "Test profile: safe qualification (default), debug diagnostics",
    ) orelse .safe) {
        .safe => .safe,
        .debug => .debug,
    };
    const namespace_registry_mod = namespaceRegistryModule(b, target, optimize);
    const namespace_registry_test_mod = namespaceRegistryModule(b, target, test_optimize);
    // Reuse the registry graph's exact Unicode modules in reader consumers.
    const unicode_lower_mod = namespace_registry_mod.import_table.get("unicode_lower").?;
    const unicode_lower_test_mod = namespace_registry_test_mod.import_table.get("unicode_lower").?;
    const language_metadata_parser_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/parser/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const language_metadata_parser_test_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/parser/root.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    // Build-only occurrence coordinates are shared by producer and receiver.
    const missing_dependency_mod = b.createModule(.{ .root_source_file = b.path("compiler/src/shared/missing_dependency.zig"), .target = target, .optimize = optimize });
    const missing_dependency_test_mod = b.createModule(.{ .root_source_file = b.path("compiler/src/shared/missing_dependency.zig"), .target = target, .optimize = test_optimize });
    const shared_xml_decode_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/shared/xml_decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_xml_decode_mod_test = b.createModule(.{
        .root_source_file = b.path("compiler/src/shared/xml_decode.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const wikimedia_dump_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/shared/wikimedia_dump.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const wikimedia_dump_mod_test = b.createModule(.{
        .root_source_file = b.path("compiler/src/shared/wikimedia_dump.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
    });
    // Parent bundle processes share the worker's bounded single-write logger.
    // This standalone module does not pull the Lua runtime into blob building.
    const build_diagnostics_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/runtime/work_stats.zig"),
        .target = target,
        .optimize = optimize,
    });
    const build_diagnostics_test_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/runtime/work_stats.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    const bundle_protocol_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/bundle_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bundle_protocol_mod_test = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/bundle_protocol.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    const blob_encoder_mod = b.addModule("blob_encoder", .{
        .root_source_file = b.path("renderer/src/format/blob_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const blob_encoder_mod_test = b.createModule(.{
        .root_source_file = b.path("renderer/src/format/blob_root.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const blob_xz_mod = b.createModule(.{ .root_source_file = b.path("renderer/src/native/xz.zig"), .target = target, .optimize = optimize });
    const storage_mod = b.createModule(.{ .root_source_file = b.path("renderer/src/native/storage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod }} });
    const lzma = b.addTranslateC(.{ .root_source_file = b.path("renderer/src/native/lzma.h"), .target = target, .optimize = optimize });
    lzma.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    storage_mod.addImport("lzma", lzma.createModule());
    blob_xz_mod.addImport("lzma", lzma.createModule());
    const storage_test = b.createModule(.{ .root_source_file = b.path("renderer/src/native/storage.zig"), .target = target, .optimize = test_optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod_test }} });
    storage_test.addImport("lzma", lzma.createModule());
    const encoder_mod = b.addModule("encoder", .{
        .root_source_file = b.path("compiler/src/encoder/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    encoder_mod.addImport("namespace_registry", namespace_registry_mod);
    encoder_mod.addImport("shared_xml_decode", shared_xml_decode_mod);
    encoder_mod.addImport("blob_encoder", blob_encoder_mod);
    encoder_mod.addImport("build_diagnostics", build_diagnostics_mod);
    encoder_mod.addImport("missing_dependency", missing_dependency_mod);

    const encoder_mod_test = b.addModule("encoder_test", .{
        .root_source_file = b.path("compiler/src/encoder/root.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    encoder_mod_test.addImport("namespace_registry", namespace_registry_test_mod);
    encoder_mod_test.addImport("shared_xml_decode", shared_xml_decode_mod_test);
    encoder_mod_test.addImport("blob_encoder", blob_encoder_mod_test);
    encoder_mod_test.addImport("build_diagnostics", build_diagnostics_test_mod);
    encoder_mod_test.addImport("missing_dependency", missing_dependency_test_mod);

    const blob_decoder_mod = b.addModule("blob_decoder", .{
        .root_source_file = b.path("renderer/src/decoder/blob_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    blob_decoder_mod.addImport("blob_encoder", blob_encoder_mod);
    const blob_decoder_mod_test = b.createModule(.{
        .root_source_file = b.path("renderer/src/decoder/blob_root.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    blob_decoder_mod_test.addImport("blob_encoder", blob_encoder_mod_test);
    const blob_wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const blob_encoder_mod_wasm = b.createModule(.{
        .root_source_file = b.path("renderer/src/format/blob_root.zig"),
        .target = blob_wasm_target,
        .optimize = test_optimize,
    });
    const blob_decoder_mod_wasm = b.createModule(.{
        .root_source_file = b.path("renderer/src/decoder/blob_root.zig"),
        .target = blob_wasm_target,
        .optimize = test_optimize,
    });
    blob_decoder_mod_wasm.addImport("blob_encoder", blob_encoder_mod_wasm);

    const lua_usage_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/usage.zig"),
        .target = target,
        .optimize = optimize,
    });
    lua_usage_mod.addImport("namespace_registry", namespace_registry_mod);
    lua_usage_mod.addImport("missing_dependency", missing_dependency_mod);
    const module_extract_exe = addCliExecutable(b, "dict-module-extract", b.path("compiler/src/lua/module_extract_main.zig"), target, optimize, &.{
        .{ .name = "xml_decode", .module = shared_xml_decode_mod },
        .{ .name = "lua_usage", .module = lua_usage_mod },
        .{ .name = "wikimedia_dump", .module = wikimedia_dump_mod },
    });
    module_extract_exe.root_module.addImport("namespace_registry", namespace_registry_mod);
    module_extract_exe.root_module.link_libc = true;
    module_extract_exe.root_module.linkSystemLibrary("bz2", .{});
    module_extract_exe.root_module.linkSystemLibrary("zstd", .{});
    const page_title_index_exe = addCliExecutable(b, "dict-page-title-index", b.path("compiler/tools/page_title_index.zig"), target, optimize, &.{
        .{ .name = "wikimedia_dump", .module = wikimedia_dump_mod },
    });
    page_title_index_exe.root_module.link_libc = true;
    page_title_index_exe.root_module.linkSystemLibrary("bz2", .{});
    page_title_index_exe.root_module.linkSystemLibrary("zstd", .{});
    const blob_build_exe = addCliExecutable(b, "dict-blob-build", b.path("compiler/tools/blob_build.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = encoder_mod },
        .{ .name = "lua_parser", .module = language_metadata_parser_mod },
        .{ .name = "xml_decode", .module = shared_xml_decode_mod },
        .{ .name = "wikimedia_dump", .module = wikimedia_dump_mod },
        .{ .name = "bundle_protocol", .module = bundle_protocol_mod },
        .{ .name = "build_diagnostics", .module = build_diagnostics_mod },
    });
    const captured_writer_options = b.addOptions();
    const captured_source_fingerprint = b.option([]const u8, "captured-source-fingerprint", "Exact immutable source binding for retained-page diagnostics") orelse "";
    captured_writer_options.addOption([]const u8, "source_fingerprint", captured_source_fingerprint);
    blob_build_exe.root_module.addOptions("captured_writer_options", captured_writer_options);
    blob_build_exe.root_module.link_libc = true;
    blob_build_exe.root_module.linkSystemLibrary("bz2", .{});
    blob_build_exe.root_module.linkSystemLibrary("zstd", .{});
    addPublicRunStep(b, "build-blobs", "Encode blobs with an already compiled bundle expander", addRunArtifactCommand(b, blob_build_exe, &.{}), &.{});
    blob_build_exe.root_module.addImport("namespace_registry", namespace_registry_mod);
    blob_build_exe.root_module.addImport("missing_dependency", missing_dependency_mod);
    const blob_merge_exe = addCliExecutable(b, "dict-blob-merge", b.path("compiler/tools/blob_merge.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = blob_encoder_mod },
    });
    blob_merge_exe.root_module.addImport("xz", blob_xz_mod);
    blob_merge_exe.root_module.link_libc = true;
    addPublicRunStep(b, "merge-blobs", "Merge non-overlapping compiled blob shards", addRunArtifactCommand(b, blob_merge_exe, &.{}), &.{});
    const blob_verify_exe = addCliExecutable(b, "dict-blob-verify", b.path("compiler/tools/blob_verify.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = blob_encoder_mod },
    });
    blob_verify_exe.root_module.addImport("xz", blob_xz_mod);
    blob_verify_exe.root_module.link_libc = true;

    const writer_cache_provenance = b.option(bool, "writer-cache-provenance", "Record retained Writer cache-output provenance") orelse false;
    const prepare_captured_writer = b.step("prepare-captured-writer", "Prepare the existing blob tool for authenticated retained-page diagnostics");
    const prepare_blob_tools = b.step("prepare-blob-tools", "Prepare native blob build, merge and verification tools");
    const prepare_blob_verify = b.step("prepare-blob-verify", "Prepare only the existing native blob verification tool");
    for ([_]*std.Build.Step.Compile{ blob_build_exe, blob_merge_exe, blob_verify_exe }) |artifact| {
        const install = b.addInstallArtifact(artifact, .{});
        prepare_blob_tools.dependOn(&install.step);
        if (artifact == blob_build_exe) {
            prepare_captured_writer.dependOn(&install.step);
            if (captured_source_fingerprint.len == 0 and !writer_cache_provenance) continue;
            // Record the actual compiler LazyPath, without searching cache indexes.
            const report = b.addSystemCommand(&.{"python3"});
            report.has_side_effects = true;
            report.addFileArg2(b.path("compiler/tools/native_qualification.py"), .{ .make_absolute = true });
            report.addArg("record-installed-cache");
            report.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "" } }, .{ .make_absolute = true });
            report.addDirectoryArg2(std.Build.LazyPath.cache_root, .{ .make_absolute = true });
            report.addArg(artifact.name);
            report.addFileArg2(artifact.getEmittedBin(), .{ .make_absolute = true });
            report.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = artifact.out_filename } }, .{ .make_absolute = true });
            report.addArg(captured_source_fingerprint);
            report.step.dependOn(&install.step);
            prepare_captured_writer.dependOn(&report.step);
            if (writer_cache_provenance) prepare_blob_tools.dependOn(&report.step);
        }
        if (artifact == blob_verify_exe) prepare_blob_verify.dependOn(&install.step);
    }

    const llvm_obj = b.addObject(.{
        .name = "dict-llvm-build-core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/src/lua/llvm_build_main.zig"),
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
        .file = b.path("compiler/tools/llvm_build_main.c"),
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
    const prepare_expander_tools = b.step("prepare-expander-tools", "Install the module extractor, LLVM compiler and shared expansion runtime");
    for ([_]*std.Build.Step.Compile{ module_extract_exe, llvm_exe }) |artifact| {
        const install = b.addInstallArtifact(artifact, .{});
        prepare_expander_tools.dependOn(&install.step);
    }
    const install_worker_object = b.addInstallFileWithDir(worker_object.getEmittedBin(), .lib, worker_object.out_filename);
    prepare_expander_tools.dependOn(&install_worker_object.step);
    b.step("prepare-expander-runtime", "Install only the shared expansion runtime").dependOn(&install_worker_object.step);
    pipeline_paths.addOptionPath("worker_object", worker_object.getEmittedBin());
    const value_leaf_object = bundleValueLeafObject(b);
    // Preserve the former build-obj producer's object+bitcode outputs. Only
    // bitcode is consumed; the leaf object must never be linked into a worker.
    _ = value_leaf_object.getEmittedBin();
    pipeline_paths.addOptionPath("value_leaf_bc", value_leaf_object.getEmittedLlvmBc());
    const native_inputs = b.addWriteFiles();
    pipeline_paths.addOptionPath("worker_main_c", native_inputs.addCopyFile(
        b.path("compiler/src/lua/bundle_worker_main.c"),
        "bundle_worker_main.c",
    ));
    pipeline_paths.addOptionPath("modules", module_extract_exe.getEmittedBin());
    pipeline_paths.addOptionPath("llvm", llvm_exe.getEmittedBin());
    pipeline_paths.addOption([]const u8, "zig", b.graph.zig_exe);
    pipeline_paths.addOption([]const u8, "clang", "clang");
    pipeline_paths.addOptionPathUntracked("project_root", b.path("."));
    pipeline_paths.addOptionPath("blobs", blob_build_exe.getEmittedBin());
    const pipeline_exe = addCliExecutable(b, "dict-bundle-build", b.path("compiler/tools/bundle_build.zig"), target, optimize, &.{.{ .name = "pipeline_paths", .module = pipeline_paths.createModule() }});
    // The caller authenticates each retained role and its original producer.
    // This selection compiles only the maintained driver and its path options;
    // it neither rebuilds nor grants qualification to the supplied artifacts.
    const retained_bundle_paths: [6]?[]const u8 = .{
        b.option([]const u8, "bundle-driver-worker-object", "Qualified retained worker object for driver-only preparation"),
        b.option([]const u8, "bundle-driver-value-leaf-bc", "Qualified retained value-leaf bitcode for driver-only preparation"),
        b.option([]const u8, "bundle-driver-worker-main-c", "Qualified retained worker C entry for driver-only preparation"),
        b.option([]const u8, "bundle-driver-modules", "Qualified retained module extractor for driver-only preparation"),
        b.option([]const u8, "bundle-driver-llvm", "Qualified retained LLVM compiler for driver-only preparation"),
        b.option([]const u8, "bundle-driver-blobs", "Qualified retained Writer for driver-only preparation"),
    };
    const retained_bundle = retainedBundleDriverSelected(retained_bundle_paths) catch |err|
        std.debug.panic("invalid retained bundle driver inputs: {s}", .{@errorName(err)});
    const prepared_bundle_driver = if (retained_bundle) blk: {
        const selected_paths = b.addOptions();
        inline for (.{ "worker_object", "value_leaf_bc", "worker_main_c", "modules", "llvm", "blobs" }, 0..) |name, i|
            selected_paths.addOption([]const u8, name, retained_bundle_paths[i].?);
        selected_paths.addOption([]const u8, "zig", b.graph.zig_exe);
        selected_paths.addOption([]const u8, "clang", "clang");
        selected_paths.addOptionPathUntracked("project_root", b.path("."));
        break :blk addCliExecutable(b, "dict-bundle-build", b.path("compiler/tools/bundle_build.zig"), target, optimize,
            &.{.{ .name = "pipeline_paths", .module = selected_paths.createModule() }});
    } else pipeline_exe;
    const install_bundle_driver = b.addInstallArtifact(prepared_bundle_driver, .{});
    b.step("prepare-bundle-driver", "Install the normal bundle driver, optionally using qualified retained native inputs").dependOn(&install_bundle_driver.step);
    addPublicRunStep(b, "build-dictionary", "Pre-expand templates/modules and emit data-only dictionary blobs", addRunArtifactCommand(b, pipeline_exe, &.{}), &.{});
    const blob_files_mod = b.createModule(.{ .root_source_file = b.path("renderer/src/format/blob_files.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod }} });
    const blob_files_mod_test = b.createModule(.{ .root_source_file = b.path("renderer/src/format/blob_files.zig"), .target = target, .optimize = test_optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod_test }} });
    // Encoder and readers share one module identity for this source file.
    blob_verify_exe.root_module.addImport("blob_files", blob_files_mod);
    encoder_mod.addImport("blob_files", blob_files_mod);
    encoder_mod_test.addImport("blob_files", blob_files_mod_test);
    const reader_name = if (target.result.os.tag == .windows or target.result.os.tag == .wasi) "dict" else "wikidict";
    const blob_query_exe = addCliExecutable(b, reader_name, b.path("renderer/src/frontend/main.zig"), target, optimize, &.{
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
        .root_source_file = b.path("renderer/src/frontend/c_api.zig"),
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
    const ffi_header_install = b.addInstallHeaderFile(b.path("renderer/src/ffi/dict.h"), "dict/dict.h");

    const ffi_test_mod = b.createModule(.{ .target = b.graph.host, .optimize = test_optimize, .link_libc = true });
    ffi_test_mod.addCSourceFile(.{ .file = b.path("compiler/tools/ffi_integration_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    ffi_test_mod.addIncludePath(b.path("renderer/src/ffi"));
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

    const test_runner = b.path("compiler/tools/test_runner.zig");
    // Unit tests invoke real Clang for owned-child cleanup, but only inspect
    // the blob command's argv. Do not build production tools for those tokens.
    const pipeline_unit_paths = b.addOptions();
    pipeline_unit_paths.addOption([]const u8, "clang", "clang");
    pipeline_unit_paths.addOption([]const u8, "blobs", "dict-blob-build-unit-test-argv-token");
    const bundle_pipeline_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/tools/bundle_build.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
            .imports = &.{
                .{ .name = "pipeline_paths", .module = pipeline_unit_paths.createModule() },
                .{ .name = "wikimedia_dump", .module = wikimedia_dump_mod_test },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const run_bundle_pipeline_tests = b.addRunArtifact(bundle_pipeline_tests);
    const run_bundle_pipeline_tests_only = b.addRunArtifact(bundle_pipeline_tests);

    const blob_build_test_options: std.Build.TestOptions = .{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/tools/blob_build.zig"),
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
    // Unit tests pass fixture fingerprints directly to the diagnostic API.
    // Only the production captured Writer embeds the current source binding.
    const captured_writer_test_options = b.addOptions();
    captured_writer_test_options.addOption([]const u8, "source_fingerprint", "");
    const blob_build_tests = b.addTest(blob_build_test_options);
    blob_build_tests.root_module.addOptions("captured_writer_options", captured_writer_test_options);
    blob_build_tests.root_module.linkSystemLibrary("bz2", .{});
    blob_build_tests.root_module.linkSystemLibrary("zstd", .{});
    blob_build_tests.root_module.addImport("namespace_registry", namespace_registry_test_mod);
    // Source membership matters only to targets which select tests by partition.
    // All partition compiles share the same cached inventory check.
    const tools_inventory = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build.zig"), .target = b.graph.host, .optimize = test_optimize,
        }),
        .filters = &.{"Tools partition source inventory"},
    }));
    const blob_build_normal_tests = b.addTest(preparedTestOptions(blob_build_tests, tools_partitions[0].filters));
    const blob_build_core_tests = b.addTest(preparedTestOptions(blob_build_tests, tools_partitions[1].filters));
    const blob_build_observations_tests = b.addTest(preparedTestOptions(blob_build_tests, tools_partitions[2].filters));
    const blob_build_support_tests = b.addTest(preparedTestOptions(blob_build_tests, tools_partitions[3].filters));
    const tools_test_parts = [_]*std.Build.Step.Compile{
        blob_build_normal_tests, blob_build_core_tests,
        blob_build_observations_tests, blob_build_support_tests,
    };
    for (tools_test_parts) |part| part.step.dependOn(&tools_inventory.step);
    // Keep heavy compiles sequential at the existing job cap. Execute each
    // independent artifact even if another partition returns test failures.
    for (tools_test_parts[1..], 0..) |part, i| part.step.dependOn(&tools_test_parts[i].step);
    const test_tools = b.step("test-tools", "Run the complete Tools inventory in bounded normal partitions");
    for (tools_test_parts) |part| {
        const run = b.addRunArtifact(part);
        test_tools.dependOn(&run.step);
    }


    const blob_file_tools_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/tools/blob_file_tools_test.zig"),
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
    const blob_xz_test_mod = b.createModule(.{ .root_source_file = b.path("renderer/src/native/xz.zig"), .target = b.graph.host, .optimize = test_optimize });
    const blob_xz_test_lzma = b.addTranslateC(.{ .root_source_file = b.path("renderer/src/native/lzma.h"), .target = b.graph.host, .optimize = test_optimize });
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
            .root_source_file = b.path("renderer/src/frontend/main.zig"),
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
            .root_source_file = b.path("compiler/src/lua/tests.zig"),
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
    lua_tests.root_module.addImport("lua_usage", lua_tests.root_module);
    lua_tests.root_module.addImport("namespace_registry", namespace_registry_test_mod);
    lua_tests.root_module.addImport("missing_dependency", missing_dependency_test_mod);
    lua_tests.root_module.linkSystemLibrary("LLVM", .{ .use_pkg_config = .no });
    lua_tests.root_module.linkSystemLibrary("bz2", .{});
    lua_tests.root_module.linkSystemLibrary("zstd", .{});
    const lua_static_fields_test_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/abi/static_fields.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const lua_globals_test_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/abi/globals.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const lua_wikitext_preprocess_test_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/wikitext/preprocess.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const lua_wikitext_expression_test_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/wikitext/expression.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    lua_wikitext_preprocess_test_mod.addImport("missing_dependency", missing_dependency_test_mod);
    const zig_runtime_test_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/runtime/core.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
    });
    zig_runtime_test_mod.addImport("namespace_registry", namespace_registry_test_mod);
    zig_runtime_test_mod.addImport("missing_dependency", missing_dependency_test_mod);
    zig_runtime_test_mod.addImport("lua_static_fields", lua_static_fields_test_mod);
    const value_leaf_test_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/value_leaf_build.zig"),
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
    lua_tests.root_module.addAnonymousImport("value_leaf_test_bitcode", .{ .root_source_file = value_leaf_test_bc });
    const lua_core_test_options: std.Build.TestOptions = .{
        .root_module = zig_runtime_test_mod,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    };
    const lua_core_tests = b.addTest(lua_core_test_options);
    const lua_core_tests_standalone = b.addTest(lua_core_test_options);
    const global_index_test_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/runtime/global_shape_index.zig"),
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
        .root_source_file = b.path("compiler/src/lua/program_metadata.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const program_shapes_test_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/runtime/program_shapes.zig"),
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
        .root_source_file = b.path("compiler/src/lua/runtime/static_literal_format.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    const static_literal_decode_test_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/runtime/static_literal_decode.zig"),
        .target = target,
        .optimize = test_optimize,
        .imports = &.{
            .{ .name = "zig_runtime", .module = zig_runtime_test_mod },
            .{ .name = "lua_static_literal_format", .module = static_literal_format_test_mod },
        },
    });
    const lua_abi_test_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/runtime/llvm_abi.zig"),
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
            .root_source_file = b.path("compiler/src/lua/runtime/stdlib.zig"),
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
            .root_source_file = b.path("compiler/src/lua/runtime/ustring.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zig_runtime", .module = zig_runtime_test_mod }},
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const lua_scribunto_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/src/lua/runtime/scribunto.zig"),
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
            .root_source_file = b.path("compiler/src/lua/runtime/wikitext.zig"),
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
            .root_source_file = b.path("compiler/tools/blob_wasm_smoke.zig"),
            .target = blob_wasm_target,
            .optimize = test_optimize,
            .imports = &.{
                .{ .name = "blob_decoder", .module = blob_decoder_mod_wasm },
            },
        }),
    });
    const test_step = b.step("test", "Run bundle encoder, data reader, Lua, and tooling tests");
    var run_encoder_tests: [encoder_partitions.len]*std.Build.Step.Run = undefined;
    for (encoder_partitions, 0..) |partition, i| {
        const run = b.addRunArtifact(encoder_tests[i]);
        if (partition.runtime_filter) |filter| run.addArgs(&.{ "--test-filter", filter });
        // The default graph serializes compilation and execution. Memory
        // reservations let prior independent tests remain sibling obligations.
        if (i != 0) addTestOrder(test_step, &encoder_tests[i].step, &run_encoder_tests[i - 1].step, test_step_memory != 0);
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

    addTestOrder(test_step, &blob_encoder_tests.step, &run_encoder_tests[encoder_partitions.len - 1].step, test_step_memory != 0);
    addTestOrder(test_step, &blob_decoder_tests.step, &run_blob_encoder_tests.step, test_step_memory != 0);
    addTestOrder(test_step, &blob_query_tests.step, &run_blob_decoder_tests.step, test_step_memory != 0);
    addTestOrder(test_step, &wikimedia_dump_tests.step, &run_blob_query_tests.step, test_step_memory != 0);
    addTestOrder(test_step, &lua_tests.step, &run_wikimedia_dump_tests.step, test_step_memory != 0);
    addTestOrder(test_step, &lua_core_tests.step, &run_lua_tests.step, test_step_memory != 0);
    addTestOrder(test_step, &global_index_tests.step, &run_lua_core_tests.step, test_step_memory != 0);
    addTestOrder(test_step, &program_shapes_tests.step, &run_global_index_tests.step, test_step_memory != 0);
    addTestOrder(test_step, &lua_abi_tests.step, &run_program_shapes_tests.step, test_step_memory != 0);
    addTestOrder(test_step, &lua_stdlib_tests.step, &run_lua_abi_tests.step, test_step_memory != 0);
    addTestOrder(test_step, &lua_ustring_tests.step, &run_lua_stdlib_tests.step, test_step_memory != 0);
    addTestOrder(test_step, &lua_scribunto_tests.step, &run_lua_ustring_tests.step, test_step_memory != 0);
    addTestOrder(test_step, &lua_wikitext_tests.step, &run_lua_scribunto_tests.step, test_step_memory != 0);
    const bundle_protocol_tests = b.addTest(.{
        .root_module = bundle_protocol_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const run_bundle_protocol_tests = b.addRunArtifact(bundle_protocol_tests);
    addTestOrder(test_step, &run_bundle_protocol_tests.step, &run_lua_wikitext_tests.step, test_step_memory != 0);

    const namespace_registry_tests = b.addTest(.{ .root_module = namespace_registry_test_mod, .test_runner = .{ .path = test_runner, .mode = .simple } });
    const run_namespace_registry_tests = b.addRunArtifact(namespace_registry_tests);
    b.step("test-namespace-registry", "Validate edition namespace and title resolution").dependOn(&run_namespace_registry_tests.step);
    addTestOrder(test_step, &lua_tests.step, &run_namespace_registry_tests.step, test_step_memory != 0);
    const program_provider_test_mod = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/runtime/llvm_program.zig"),
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
    const page_language_provider_mod = b.createModule(.{
        .root_source_file = b.path("compiler/tools/page_language.zig"), .target = target, .optimize = test_optimize,
        .imports = &.{
            .{ .name = "namespace_registry", .module = namespace_registry_test_mod },
            // The prefix parser uses the shared data-only syntax API.
            .{ .name = "encoder", .module = blob_encoder_mod_test },
        },
    });
    const provider_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/bundle_pages.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "lua_program", .module = program_provider_test_mod },
            .{ .name = "page_language", .module = page_language_provider_mod },
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
        .root_source_file = b.path("compiler/src/lua/extract/usage_closure.zig"),
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
    const missing_dependency_tests = b.addTest(.{ .root_module = missing_dependency_test_mod, .test_runner = .{ .path = test_runner, .mode = .simple } });
    const run_missing_dependency_tests = b.addRunArtifact(missing_dependency_tests);
    test_step.dependOn(&run_missing_dependency_tests.step);
    b.step("test-lua-core", "Run Lua runtime core tests serially").dependOn(&run_lua_core_tests_only.step);
    b.step("test-global-index", "Run Lua global-name index tests serially").dependOn(&run_global_index_tests_only.step);
    b.step("test-lua-abi", "Run Lua LLVM ABI tests serially").dependOn(&run_lua_abi_tests_only.step);
    addTestOrder(test_step, &blob_wasm_smoke.step, &run_bundle_protocol_tests.step, test_step_memory != 0);
    addTestOrder(test_step, &run_bundle_pipeline_tests.step, &blob_wasm_smoke.step, test_step_memory != 0);
    // Separate run steps keep the standalone Tools entry free of pipeline
    // obligations. All four use the same compiled artifacts and runner.
    for (tools_test_parts) |part| {
        const run = b.addRunArtifact(part);
        addToolsRunObligation(test_step, &run.step, &run_bundle_pipeline_tests.step, &run_blob_file_tools_tests.step, test_step_memory != 0);
    }
    test_step.dependOn(&run_blob_file_tools_tests.step);
    test_step.dependOn(&run_closure_tests.step);
    test_step.dependOn(&run_provider_tests.step);
    b.step("test-bundle-pipeline", "Run bundle build scheduler and cache bitmap unit tests only").dependOn(&run_bundle_pipeline_tests_only.step);
    const media_fetch_exe = addCliExecutable(b, "dict-media-fetch", b.path("compiler/tools/media_fetch.zig"), target, optimize, &.{ .{ .name = "media_types", .module = b.createModule(.{ .root_source_file = b.path("renderer/src/frontend/media_types.zig"), .target = target, .optimize = optimize }) }, .{ .name = "shared_xml_decode", .module = shared_xml_decode_mod } });
    addPublicRunStep(b, "fetch-media", "Download bounded attributed Wikimedia assets for an export", addRunArtifactCommand(b, media_fetch_exe, &.{}), &.{});
    const bundle_test_exe = addCliExecutable(b, "dict-bundle-integration-test", b.path("compiler/tools/bundle_integration_test.zig"), b.graph.host, test_optimize, &.{ .{ .name = "bundle_protocol", .module = bundle_protocol_mod_test }, .{ .name = "namespace_registry", .module = namespace_registry_test_mod } });
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
    const reader_test_exe = addCliExecutable(b, "dict-reader-integration-test", b.path("compiler/tools/reader_integration_test.zig"), b.graph.host, test_optimize, &.{.{ .name = "blob_encoder", .module = blob_encoder_mod_test }});
    reader_test_exe.root_module.addImport("encoder", encoder_mod_test);
    const reader_test_run = b.addRunArtifact(reader_test_exe);
    reader_test_run.addFileArg(blob_query_exe.getEmittedBin());
    reader_test_run.addFileArg(ffi_test_exe.getEmittedBin());
    reader_test_run.setCwd(b.path("."));
    reader_test_run.addDirectoryArg2(std.Build.LazyPath.cache_root, .{ .make_absolute = true });
    b.step("test-reader", "Exercise precompiled data-only reading through CLI and C FFI").dependOn(&reader_test_run.step);
    const index_blobs_exe = addCliExecutable(b, "dict-index-blobs", b.path("compiler/tools/index_blobs.zig"), target, optimize, &.{.{ .name = "blob_storage", .module = storage_mod }});
    index_blobs_exe.root_module.link_libc = true;
    index_blobs_exe.use_llvm = true;
    index_blobs_exe.use_lld = true;
    addPublicRunStep(b, "index-blobs", "Build or reuse external raw/XZ record indexes after compression", addRunArtifactCommand(b, index_blobs_exe, &.{}), &.{});
    const storage_exe = addCliExecutable(b, "dict-storage-integration-test", b.path("compiler/tools/storage_integration_test.zig"), target, test_optimize, &.{ .{ .name = "blob_encoder", .module = blob_encoder_mod_test }, .{ .name = "blob_storage", .module = storage_test } });
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
    const storage_test_step = b.step("test-storage", "Exercise after-compression indexes and selective real XZ block decoding");
    addTestOrder(storage_test_step, &storage_unit_run.step, &reader_test_run.step, test_step_memory != 0);
    addTestOrder(storage_test_step, &storage_run.step, &storage_unit_run.step, test_step_memory != 0);
    storage_test_step.dependOn(&storage_run.step);
    if (target.result.os.tag == b.graph.host.result.os.tag and target.result.cpu.arch == b.graph.host.result.cpu.arch)
        test_step.dependOn(if (test_step_memory != 0) storage_test_step else &storage_run.step);

    // Only prepared artifacts use these filters. The public full test graph
    // above remains unfiltered, including when these options are supplied.
    const prepare_group = b.option(PreparedTestGroup, "prepare-test-group", "Compile only this prepare-tests group");
    const requested_filters = b.option([]const []const u8, "prepare-test-filter", "Repeat to compile named tests in the selected prepare-tests group") orelse &.{};
    const prepare_error_tracing = b.option(bool, "prepare-test-error-tracing", "Enable error-return traces for selected prepared test roots") orelse false;
    const prepare_no_emit = b.option(bool, "prepare-test-no-emit", "Check selected tests without emitting or running a test binary") orelse false;
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
        .{ .group = .tools_normal, .artifact = blob_build_normal_tests },
        .{ .group = .tools_core, .artifact = blob_build_core_tests },
        .{ .group = .tools_observations, .artifact = blob_build_observations_tests },
        .{ .group = .tools_support, .artifact = blob_build_support_tests },
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
    // Debug qualification uses LLVM after the retained diagnostic artifact
    // faulted on an aligned AVX stack load at an observed misaligned address.
    // preparedTestOptions preserves this backend for every selected clone.
    if (test_optimize == .debug) {
        for (prepared_tests) |prepared| {
            prepared.artifact.use_llvm = true;
        }
    }
    const cache_report_dependencies = b.option(bool, "qualification-cache-dependencies", "Report selected dependencies without changing legacy retention") orelse false;
    const cache_report_path = b.option([]const u8, "qualification-cache-report", "Optional test artifact metadata report");
    const cache_report_family = b.option(enum { prepare, full }, "qualification-cache-family", "Already selected graph to report");
    const cache_report_recorder = b.option([]const u8, "qualification-cache-recorder", "Bound qualification helper");
    const cache_report_context = b.option([]const u8, "qualification-cache-context", "Bound qualification context SHA256");
    validatePreparedTestEmission(prepare_no_emit, prepare_group, cache_report_dependencies or cache_report_path != null or cache_report_family != null or cache_report_recorder != null or cache_report_context != null) catch |err| {
        std.log.err("invalid prepare-tests emission: {s}", .{@errorName(err)});
        b.invalid_user_input = true;
        return;
    };
    const cache_report = if (cache_report_path != null and cache_report_family != null and cache_report_recorder != null and cache_report_context != null) b.addSystemCommand(&.{
        "python3", cache_report_recorder.?, "record-test-cache", cache_report_path.?,
    }) else null;
    if (cache_report) |report| {
        report.has_side_effects = true;
        report.addDirectoryArg2(std.Build.LazyPath.cache_root, .{ .make_absolute = true });
        report.addArg(cache_report_context.?);
        if (cache_report_dependencies) report.addArgs(&.{ "dependency_report_v2", "selected" });
        b.step("qualification-cache-artifacts", "Report already selected test cache paths only").dependOn(&report.step);
        if (cache_report_family.? == .full) {
            // Full Run/tail dependencies are not enrolled by the test clones.
            if (cache_report_dependencies) report.addArgs(&.{ "dependency_graph_unknown", "full-run-dependencies" });
            for (prepared_tests) |prepared| {
                if (prepared.group == .tools) continue; // Focused legacy root is not part of the full graph.
                report.addArg(@tagName(prepared.group));
                const same_options = b.addTest(preparedTestOptions(prepared.artifact, &.{}));
                report.addArtifactArg2(same_options, .{ .make_absolute = true });
                if (cache_report_dependencies) reportSelectedDependencies(b, report, &same_options.step);
            }
        }
    } else {
        _ = b.step("qualification-cache-artifacts", "Report already selected test cache paths only");
    }
    const prepare_tests = b.step("prepare-tests", "Compile test executables for runtime-filtered qualification");
    if (cache_report != null and cache_report_family.? == .full) return;
    // The normal pipeline group also requires the reader's freestanding smoke
    // compilation. Clone only that object, not its serial protocol-test run.
    if (prepare_group == .bundle_pipeline) {
        if (cache_report_dependencies) {
            if (cache_report) |report| report.addArgs(&.{ "dependency_graph_unknown", "selected-extra-object" });
        }
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
        const compiled = b.addTest(options);
        if (prepare_no_emit) {
            // No artifact consumer: Zig performs semantic analysis without emitting a binary.
            prepare_tests.dependOn(&compiled.step);
            return;
        }
        if (cache_report) |report| {
            report.addArg("encoder");
            report.addArtifactArg2(compiled, .{ .make_absolute = true });
            if (cache_report_dependencies) reportSelectedDependencies(b, report, &compiled.step);
        }
        const install = b.addInstallArtifact(compiled, .{ .dest_sub_path = "wikidict-tests/encoder" });
        prepare_tests.dependOn(&install.step);
        return;
    }
    var previous_prepared_encoder: ?*std.Build.Step = null;
    var previous_prepared_tools: ?*std.Build.Step = null;
    for (prepared_tests) |prepared| {
        if (!preparedTestGroupIncluded(prepare_group, prepared.group)) continue;
        const selected_filters = if (isToolsPartition(prepared.group)) toolsPartitionFilters(prepared.group) else prepare_filters;
        var options = preparedTestOptions(prepared.artifact, selected_filters);
        options.root_module = preparedRoot(b, options.root_module, prepare_error_tracing);
        const compiled = b.addTest(options);
        if (cache_report) |report| {
            report.addArg(@tagName(prepared.group));
            report.addArtifactArg2(compiled, .{ .make_absolute = true });
            if (cache_report_dependencies) reportSelectedDependencies(b, report, &compiled.step);
        }
        if (isEncoderPartition(prepared.group)) {
            if (previous_prepared_encoder) |previous| compiled.step.dependOn(previous);
        }
        if (isToolsPartition(prepared.group)) {
            compiled.step.dependOn(&tools_inventory.step);
            if (previous_prepared_tools) |previous| compiled.step.dependOn(previous);
            previous_prepared_tools = &compiled.step;
        }
        if (prepare_no_emit) {
            if (isEncoderPartition(prepared.group)) previous_prepared_encoder = &compiled.step;
            prepare_tests.dependOn(&compiled.step);
            continue;
        }
        const install = b.addInstallArtifact(compiled, .{
            .dest_sub_path = b.fmt("wikidict-tests/{s}", .{@tagName(prepared.group)}),
        });
        if (isEncoderPartition(prepared.group)) previous_prepared_encoder = &install.step;
        prepare_tests.dependOn(&install.step);
    }
}

// Export only outputs already requested by the selected graph. In particular,
// asking an otherwise unused Compile for getEmittedBin would create new work.
fn reportSelectedDependencies(b: *std.Build, report: *std.Build.Step.Run, root: *std.Build.Step) void {
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    defer seen.deinit(b.allocator);
    reportDependencyStep(b, report, root, root, &seen);
}

fn reportDependencyStep(b: *std.Build, report: *std.Build.Step.Run, step: *std.Build.Step,
    root: *std.Build.Step, seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) void
{
    const entry = seen.getOrPut(b.allocator, step) catch @panic("OOM");
    if (entry.found_existing) return;
    if (step != root) {
        if (step.cast(std.Build.Step.Run) != null) {
            report.addArgs(&.{ "dependency_graph_unknown", "run-step" });
            return; // Never acquire a test Run dependency merely to report paths.
        }
        if (step.cast(std.Build.Step.Compile)) |compiled| {
            if (compiled.generated_bin == .none) {
                report.addArgs(&.{ "dependency_graph_unknown", "unrequested-output" });
            } else {
                report.addArg("dependency");
                report.addArtifactArg2(compiled, .{ .make_absolute = true });
            }
        }
    }
    for (step.dependencies.items) |dependency| reportDependencyStep(b, report, dependency, root, seen);
}

fn bundleValueLeafObject(b: *std.Build) *std.Build.Step.Compile {
    // Match build-obj -Ofast -mcpu=baseline -fllvm -fstrip -lc. This graph is
    // separate from the native-CPU worker graph so its imports also retain
    // baseline CPU features and the build_value_leaf root's extern TLS mode.
    const target = b.resolveTargetQuery(.{ .cpu_model = .baseline });
    const namespace = namespaceRegistryModule(b, target, .fast);
    const fields = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/abi/static_fields.zig"),
        .target = target,
        .optimize = .fast,
    });
    const runtime = b.createModule(.{
        .root_source_file = b.path("compiler/src/lua/runtime/core.zig"),
        .target = target,
        .optimize = .fast,
        .imports = &.{
            .{ .name = "lua_static_fields", .module = fields },
            .{ .name = "namespace_registry", .module = namespace },
        },
    });
    runtime.addImport("missing_dependency", b.createModule(.{ .root_source_file = b.path("compiler/src/shared/missing_dependency.zig"), .target = target, .optimize = .fast }));
    return b.addObject(.{
        .name = "value_leaf_build",
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/src/lua/value_leaf_build.zig"),
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
    const fields = workerModule(b, "compiler/src/lua/abi/static_fields.zig");
    const globals = workerModule(b, "compiler/src/lua/abi/globals.zig");
    const metadata = workerModule(b, "compiler/src/lua/program_metadata.zig");
    const static_format = workerModule(b, "compiler/src/lua/runtime/static_literal_format.zig");
    const preprocess = workerModule(b, "compiler/src/lua/wikitext/preprocess.zig");
    const expression = workerModule(b, "compiler/src/lua/wikitext/expression.zig");
    const xml = workerModule(b, "compiler/src/shared/xml_decode.zig");
    const dump = workerModule(b, "compiler/src/shared/wikimedia_dump.zig");
    const missing_dependency = workerModule(b, "compiler/src/shared/missing_dependency.zig");
    preprocess.addImport("missing_dependency", missing_dependency);
    const runtime = workerModule(b, "compiler/src/lua/runtime/core.zig");
    runtime.addImport("lua_static_fields", fields);
    runtime.addImport("namespace_registry", namespace);
    runtime.addImport("missing_dependency", missing_dependency);
    const static_decode = workerModule(b, "compiler/src/lua/runtime/static_literal_decode.zig");
    static_decode.addImport("zig_runtime", runtime);
    static_decode.addImport("lua_static_literal_format", static_format);
    const stdlib = workerModule(b, "compiler/src/lua/runtime/stdlib.zig");
    stdlib.addImport("zig_runtime", runtime);
    stdlib.addImport("lua_globals", globals);
    const scribunto = workerModule(b, "compiler/src/lua/runtime/scribunto.zig");
    scribunto.addImport("zig_runtime", runtime);
    scribunto.addImport("zig_stdlib", stdlib);
    scribunto.addImport("lua_wikitext_preprocess", preprocess);
    scribunto.addImport("lua_wikitext_expression", expression);
    scribunto.addImport("shared_xml_decode", xml);
    scribunto.addImport("missing_dependency", missing_dependency);
    const program = workerModule(b, "compiler/src/lua/runtime/llvm_program.zig");
    program.addImport("zig_runtime", runtime);
    program.addImport("zig_stdlib", stdlib);
    program.addImport("zig_scribunto", scribunto);
    program.addImport("lua_globals", globals);
    program.addImport("lua_program_metadata", metadata);
    program.addImport("lua_static_literal_decode", static_decode);
    const abi = workerModule(b, "compiler/src/lua/runtime/llvm_abi.zig");
    abi.addImport("zig_runtime", runtime);
    abi.addImport("lua_static_literal_decode", static_decode);
    abi.addImport("lua_static_literal_format", static_format);
    const page_language_provider = workerModule(b, "compiler/tools/page_language.zig");
    page_language_provider.addImport("namespace_registry", namespace);
    // The prefix parser shares the data-only syntax API with provider tests.
    const page_language_encoder = workerModule(b, "renderer/src/format/blob_root.zig");
    page_language_provider.addImport("encoder", page_language_encoder);
    const root = workerModule(b, "compiler/src/lua/bundle_worker.zig");
    root.addImport("page_language", page_language_provider);
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
    const unicode = b.createModule(.{ .root_source_file = b.path("renderer/src/frontend/unicode_lower.zig"), .target = target, .optimize = optimize });
    return b.createModule(.{ .root_source_file = b.path("compiler/src/shared/namespace_registry_module.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "unicode_lower", .module = unicode }} });
}

const PreparedTestGroup = enum {
    encoder, encoder_compile, encoder_document, encoder_writer, encoder_support, lua, lua_core, lua_abi, lua_stdlib, lua_wikitext, tools, tools_partitioned, tools_normal, tools_core, tools_observations, tools_support, closure, provider, storage_unit, namespace_registry, blob_encoder, blob_decoder, blob_query, wikimedia_dump, global_index, program_shapes, lua_ustring, lua_scribunto, bundle_protocol, bundle_pipeline, blob_file_tools, missing_dependency
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
        "presentation_layout.test.", "presentation_media.test.", "presentation_image_map.test.",
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
    traced.import_table = original.import_table.clone(b.allocator) catch @panic("OOM");
    for (traced.import_table.values()) |*dependency| {
        if (dependency.* == original) dependency.* = traced;
    }
    traced.cached_graph = .{ .modules = &.{}, .names = &.{} };
    traced.error_tracing = true;
    return traced;
}

fn preparedTestGroupIncluded(selected: ?PreparedTestGroup, group: PreparedTestGroup) bool {
    if (selected) |wanted| {
        if (wanted == .encoder) return isEncoderPartition(group);
        if (wanted == .tools_partitioned) return isToolsPartition(group);
        return wanted == group;
    }
    // Seven logical suites, with Encoder and Tools each using four artifacts.
    // Other normal roots remain opt-in, never implicit suite completion.
    return switch (group) {
        .encoder_compile, .encoder_document, .encoder_writer, .encoder_support,
        .lua, .lua_core, .lua_abi, .lua_stdlib, .lua_wikitext,
        .tools_normal, .tools_core, .tools_observations, .tools_support => true,
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

fn validatePreparedTestEmission(no_emit: bool, group: ?PreparedTestGroup, requires_artifact: bool) !void {
    if (!no_emit) return;
    if (group == null) return error.PrepareTestGroupRequired;
    if (requires_artifact) return error.PrepareTestArtifactRequired;
}

fn preparedTestFilters(a: std.mem.Allocator, group: ?PreparedTestGroup, requested: []const []const u8) ![]const []const u8 {
    if (requested.len == 0) return &.{};
    const selected = group orelse return error.PrepareTestGroupRequired;
    for (requested) |filter| if (filter.len == 0) return error.EmptyTestFilter;
    // Zig's filters are ORed substrings, not an intersection with a partition.
    // Explicit focused filters continue to use -Dprepare-test-group=encoder.
    if (isEncoderPartition(selected)) return error.EncoderPartitionFilterNotSupported;
    if (isToolsPartition(selected) or selected == .tools_partitioned) return error.ToolsPartitionFilterNotSupported;
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

test "prepared test no emission requires a selected group and refuses artifact consumers" {
    try validatePreparedTestEmission(false, null, true);
    try validatePreparedTestEmission(true, .encoder_compile, false);
    try validatePreparedTestEmission(true, .encoder, false);
    try std.testing.expectError(error.PrepareTestGroupRequired, validatePreparedTestEmission(true, null, false));
    try std.testing.expectError(error.PrepareTestArtifactRequired, validatePreparedTestEmission(true, .encoder_compile, true));
}

test "prepared test no emission retains partition filters and normal test options" {
    var module: std.Build.Module = undefined;
    var original: std.Build.Step.Compile = undefined;
    original.kind = .@"test";
    original.name = "test";
    original.root_module = &module;
    original.step.max_rss = 321;
    original.filters = encoder_partitions[0].filters;
    original.test_runner = .{ .path = .{ .cwd_relative = "compiler/tools/test_runner.zig" }, .mode = .simple };
    original.use_llvm = true;
    original.use_lld = true;
    original.zig_lib_dir = null;
    try validatePreparedTestEmission(true, .encoder_compile, false);
    const options = preparedTestOptions(&original, &.{});
    try std.testing.expect(options.root_module == original.root_module);
    try std.testing.expect(options.filters.ptr == original.filters.ptr);
    try std.testing.expectEqualStrings("presentation_compile.test.", options.filters[0]);
    try std.testing.expectEqualStrings(encoder_discovery_filter, options.filters[1]);
    try std.testing.expectEqualStrings("compiler/tools/test_runner.zig", options.test_runner.?.path.cwd_relative);
    try std.testing.expect(options.test_runner.?.mode == .simple);
    try std.testing.expectEqual(@as(?bool, true), options.use_llvm);
    try std.testing.expectEqual(@as(?bool, true), options.use_lld);
    try std.testing.expectEqual(@as(u64, 321), options.max_rss);
    // A traced preparation must retain self imports on the cloned root,
    // without changing the normal root or its external dependency bindings.
    var build_context: std.Build = undefined;
    build_context.allocator = std.testing.allocator;
    var build_graph: std.Build.Graph = undefined;
    build_graph.arena = std.testing.allocator;
    build_context.graph = &build_graph;
    var imported: std.Build.Module = undefined;
    module.import_table = .empty;
    defer module.import_table.deinit(std.testing.allocator);
    try module.import_table.put(std.testing.allocator, "lua_usage", &module);
    try module.import_table.put(std.testing.allocator, "external", &imported);
    module.cached_graph = .{ .modules = &.{&module}, .names = &.{"root"} };
    module.error_tracing = false;
    try std.testing.expect(preparedRoot(&build_context, &module, false) == &module);
    const traced = preparedRoot(&build_context, &module, true);
    defer std.testing.allocator.destroy(traced);
    defer traced.import_table.deinit(std.testing.allocator);
    try std.testing.expect(traced.import_table.get("lua_usage").? == traced);
    try std.testing.expect(traced.import_table.get("external").? == &imported);
    try std.testing.expect(module.import_table.get("lua_usage").? == &module);
    try std.testing.expect(module.import_table.get("external").? == &imported);
    try std.testing.expect(traced.error_tracing.? and !module.error_tracing.?);
    try std.testing.expectEqual(@as(usize, 0), traced.cached_graph.modules.len);
    try std.testing.expect(module.cached_graph.modules[0] == &module);
}

test "prepared test default retains seven logical suites with partitioned Encoder and Tools" {
    var count: usize = 0;
    for (std.meta.tags(PreparedTestGroup)) |group| {
        if (preparedTestGroupIncluded(null, group)) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 13), count);
    for ([_]PreparedTestGroup{ .encoder_compile, .encoder_document, .encoder_writer, .encoder_support, .lua, .lua_core, .lua_abi, .lua_stdlib, .lua_wikitext, .tools_normal, .tools_core, .tools_observations, .tools_support }) |group| {
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
    original.test_runner = .{ .path = .{ .cwd_relative = "compiler/tools/test_runner.zig" }, .mode = .simple };
    original.use_llvm = true;
    original.use_lld = true;
    original.zig_lib_dir = .{ .cwd_relative = "zig-lib" };
    const options = preparedTestOptions(&original, &.{"one"});
    try std.testing.expect(options.root_module == &module);
    try std.testing.expectEqualStrings("test", options.name);
    try std.testing.expectEqual(@as(u64, 321), options.max_rss);
    try std.testing.expectEqual(@as(?bool, true), options.use_llvm);
    try std.testing.expectEqual(@as(?bool, true), options.use_lld);
    try std.testing.expectEqualStrings("compiler/tools/test_runner.zig", options.test_runner.?.path.cwd_relative);
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
        .{ .name = "presentation_image_map.test.same", .group = .encoder_support },
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

fn retainedBundleDriverSelected(paths: [6]?[]const u8) error{ PartialRetainedBundleInputs, InvalidRetainedBundlePath }!bool {
    var present: usize = 0;
    for (paths) |path| {
        if (path) |value| {
            if (value.len == 0 or !std.fs.path.isAbsolute(value)) return error.InvalidRetainedBundlePath;
            present += 1;
        }
    }
    if (present == 0) return false;
    if (present != paths.len) return error.PartialRetainedBundleInputs;
    return true;
}

test "bundle driver preparation leaves default production dependency selection intact" {
    try std.testing.expect(!try retainedBundleDriverSelected(.{ null, null, null, null, null, null }));
    try std.testing.expect(try retainedBundleDriverSelected(.{
        "/qualified/worker.o", "/qualified/value-leaf.bc", "/qualified/worker-main.c",
        "/qualified/module-extract", "/qualified/llvm-build", "/qualified/blob-build",
    }));
}

test "retained bundle driver preparation requires the entire qualified role tuple" {
    const complete: [6]?[]const u8 = .{
        "/qualified/worker.o", "/qualified/value-leaf.bc", "/qualified/worker-main.c",
        "/qualified/module-extract", "/qualified/llvm-build", "/qualified/blob-build",
    };
    for (0..complete.len) |missing| {
        var partial = complete;
        partial[missing] = null;
        try std.testing.expectError(error.PartialRetainedBundleInputs, retainedBundleDriverSelected(partial));
    }
}

test "retained bundle driver preparation rejects empty and relative artifact paths" {
    const complete: [6]?[]const u8 = .{
        "/qualified/worker.o", "/qualified/value-leaf.bc", "/qualified/worker-main.c",
        "/qualified/module-extract", "/qualified/llvm-build", "/qualified/blob-build",
    };
    for (0..complete.len) |invalid_index| {
        for ([_][]const u8{ "", "relative/artifact" }) |invalid| {
            var selected = complete;
            selected[invalid_index] = invalid;
            try std.testing.expectError(error.InvalidRetainedBundlePath, retainedBundleDriverSelected(selected));
        }
    }
}

// The scheduler claims memory before dispatching either a worker or an inline
// step. This opt-in uses the existing claims rather than failure dependencies.
fn validateQualificationStepMemory(bytes: u64) !void {
    // Zig 0.17 serializes claims in 256-byte units inside a u32.
    if (bytes % 256 != 0 or bytes > 0xffff_ffff00) return error.InvalidStepMemoryClaim;
}

fn claimQualificationMemory(b: *std.Build, bytes: u64) void {
    if (bytes == 0) return;
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    defer seen.deinit(b.allocator);
    for (b.top_level_steps.values()) |top| claimQualificationStep(b, &top.step, bytes, &seen);
    // Module-generated dependencies enter Step.dependencies during Serialize.
    // Their already-requested output owners are registered here beforehand.
    // Do not call getEmitted* or create dependencies merely to annotate them.
    for (b.graph.generated_files.items) |step| claimQualificationStep(b, step, bytes, &seen);
}

fn claimQualificationStep(b: *std.Build, step: *std.Build.Step, bytes: u64,
    seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) void
{
    const entry = seen.getOrPut(b.allocator, step) catch @panic("OOM");
    if (entry.found_existing) return;
    switch (step.tag) {
        .compile, .run, .translate_c => step.max_rss = @max(step.max_rss, bytes),
        else => {},
    }
    for (step.dependencies.items) |dependency| claimQualificationStep(b, dependency, bytes, seen);
}

test "qualification memory claims cover late clones runs and registered generated dependencies without enrolling work" {
    var b: std.Build = undefined;
    b.allocator = std.testing.allocator;
    b.top_level_steps = .{};
    defer b.top_level_steps.deinit(b.allocator);
    var graph: std.Build.Graph = undefined;
    b.graph = &graph;
    var top: std.Build.Step.TopLevel = undefined;
    top.step.tag = .top_level;
    top.step.max_rss = 0;
    var run: std.Build.Step = undefined;
    run.tag = .run;
    run.max_rss = 0;
    var clone: std.Build.Step = undefined;
    clone.tag = .compile;
    clone.max_rss = 0;
    clone.dependencies = .empty;
    var translate: std.Build.Step = undefined;
    translate.tag = .translate_c;
    translate.max_rss = 0;
    var linked: std.Build.Step = undefined;
    linked.tag = .compile;
    linked.max_rss = 0;
    linked.dependencies = .empty;
    var untouched: std.Build.Step = undefined;
    untouched.tag = .compile;
    untouched.max_rss = 0;
    untouched.dependencies = .empty;
    var root_deps = [_]*std.Build.Step{&run};
    top.step.dependencies = .initBuffer(&root_deps);
    top.step.dependencies.items = &root_deps;
    var run_deps = [_]*std.Build.Step{ &clone, &top.step };
    run.dependencies = .initBuffer(&run_deps);
    run.dependencies.items = &run_deps;
    var generated_deps = [_]*std.Build.Step{&linked};
    translate.dependencies = .initBuffer(&generated_deps);
    translate.dependencies.items = &generated_deps;
    var generated = [_]*std.Build.Step{ &translate, &clone, &translate };
    graph.generated_files = .initBuffer(&generated);
    graph.generated_files.items = &generated;
    try b.top_level_steps.put(b.allocator, "prepare-tests", &top);
    // A clone attached late (including on an early-return path) is present
    // when the deferred annotation runs. The duplicate and cycle are harmless.
    const claim: u64 = 6 * 1024 * 1024 * 1024;
    claimQualificationMemory(&b, 0);
    try std.testing.expectEqual(@as(u64, 0), run.max_rss);
    claimQualificationMemory(&b, claim);
    for ([_]*std.Build.Step{ &run, &clone, &translate, &linked }) |step|
        try std.testing.expectEqual(claim, step.max_rss);
    try std.testing.expectEqual(@as(u64, 0), top.step.max_rss);
    try std.testing.expectEqual(@as(u64, 0), untouched.max_rss);
    try std.testing.expectEqual(@as(usize, 1), b.top_level_steps.count());
    try std.testing.expectEqualSlices(*std.Build.Step, &.{&run}, top.step.dependencies.items);
    try std.testing.expectEqualSlices(*std.Build.Step, &.{ &clone, &top.step }, run.dependencies.items);
    try std.testing.expectEqualSlices(*std.Build.Step, &.{&linked}, translate.dependencies.items);
    try std.testing.expectEqualSlices(*std.Build.Step, &.{ &translate, &clone, &translate }, graph.generated_files.items);
    // Existing larger claims must refuse an insufficient runner budget, not
    // be silently reduced by the selected qualification reservation.
    linked.max_rss = claim + 256;
    claimQualificationMemory(&b, claim);
    try std.testing.expectEqual(claim + 256, linked.max_rss);
}

test "qualification memory claims preserve exact scheduler units and disabled behavior" {
    try validateQualificationStepMemory(0);
    try validateQualificationStepMemory(6 * 1024 * 1024 * 1024);
    try validateQualificationStepMemory(0xffff_ffff00);
    try std.testing.expectError(error.InvalidStepMemoryClaim, validateQualificationStepMemory(1));
    try std.testing.expectError(error.InvalidStepMemoryClaim, validateQualificationStepMemory(257));
    try std.testing.expectError(error.InvalidStepMemoryClaim, validateQualificationStepMemory(0x1_0000_000000));
    try std.testing.expectError(error.InvalidStepMemoryClaim, validateQualificationStepMemory(std.math.maxInt(u64)));
    var b: std.Build = undefined;
    // The disabled route must not inspect or alter any graph state.
    claimQualificationMemory(&b, 0);
    const claim: u64 = 6 * 1024 * 1024 * 1024;
    try std.testing.expectEqual(claim, std.Build.Configuration.MaxRss.fromBytes(claim).toBytes());
    try std.testing.expect(claim + claim > claim);
}

// Each dependent remains reachable through its real artifact consumer. Without
// memory claims, preserve the old serial order; with claims, keep the prior
// independent obligation on the aggregate without propagating its failure.
fn addTestOrder(aggregate: *std.Build.Step, dependent: *std.Build.Step,
    prerequisite: *std.Build.Step, memory_claims: bool) void
{
    if (memory_claims) aggregate.dependOn(prerequisite) else dependent.dependOn(prerequisite);
}

test "memory scheduled test roots preserve reachable obligations and real artifact dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b: std.Build = undefined;
    b.allocator = arena.allocator();
    var nodes: [7]std.Build.Step = undefined;
    for (&nodes) |*step| {
        step.owner = &b;
        step.dependencies = .empty;
    }
    const root = &nodes[0];
    const dependent = &nodes[1];
    const prerequisite = &nodes[2];
    const dependent_artifact = &nodes[3];
    const prerequisite_artifact = &nodes[4];
    const shared_input = &nodes[5];
    const standalone_duplicate = &nodes[6];
    root.dependOn(dependent);
    dependent.dependOn(dependent_artifact);
    prerequisite.dependOn(prerequisite_artifact);
    dependent_artifact.dependOn(shared_input);
    prerequisite_artifact.dependOn(shared_input);
    const Reach = struct {
        fn has(from: *std.Build.Step, wanted: *std.Build.Step) bool {
            if (from == wanted) return true;
            for (from.dependencies.items) |dependency| {
                if (has(dependency, wanted)) return true;
            }
            return false;
        }
    };
    addTestOrder(root, dependent, prerequisite, false);
    for (nodes[0..6]) |*step| try std.testing.expect(Reach.has(root, step));
    try std.testing.expect(!Reach.has(root, standalone_duplicate));
    try std.testing.expect(Reach.has(dependent, prerequisite));
    try std.testing.expectEqualSlices(*std.Build.Step, &.{dependent}, root.dependencies.items);
    try std.testing.expectEqualSlices(*std.Build.Step, &.{ dependent_artifact, prerequisite }, dependent.dependencies.items);

    // Reconfigure the same objects in memory mode, retaining both real inputs.
    dependent.dependencies.shrinkRetainingCapacity(1);
    addTestOrder(root, dependent, prerequisite, true);
    for (nodes[0..6]) |*step| try std.testing.expect(Reach.has(root, step));
    try std.testing.expect(!Reach.has(root, standalone_duplicate));
    // A prior test failure no longer blocks the independent consumer. A real
    // artifact or shared input failure still blocks its existing consumers.
    try std.testing.expect(!Reach.has(dependent, prerequisite));
    try std.testing.expect(Reach.has(dependent, dependent_artifact));
    try std.testing.expect(Reach.has(dependent, shared_input));
    try std.testing.expect(Reach.has(prerequisite, prerequisite_artifact));
    try std.testing.expect(Reach.has(prerequisite, shared_input));
    try std.testing.expectEqualSlices(*std.Build.Step, &.{ dependent, prerequisite }, root.dependencies.items);
    try std.testing.expectEqualSlices(*std.Build.Step, &.{dependent_artifact}, dependent.dependencies.items);
    try std.testing.expectEqualSlices(*std.Build.Step, &.{prerequisite_artifact}, prerequisite.dependencies.items);
    try std.testing.expectEqualSlices(*std.Build.Step, &.{shared_input}, dependent_artifact.dependencies.items);
    try std.testing.expectEqualSlices(*std.Build.Step, &.{shared_input}, prerequisite_artifact.dependencies.items);
}

const ToolsPartition = struct {
    group: PreparedTestGroup,
    filters: []const []const u8,
};
// Keep the original root, module graph, names and backend. A new top-level
// naming family must update these disjoint boundaries rather than disappear.
const tools_partitions = [_]ToolsPartition{
    .{ .group = .tools_normal, .filters = &.{
        "blob_build.test.normal ",
    } },
    .{ .group = .tools_core, .filters = &.{
        "blob_build.test.AF ",
        "blob_build.test.AN ",
        "blob_build.test.AY ",
        "blob_build.test.Aal ",
        "blob_build.test.Amharic ",
        "blob_build.test.Arabic ",
        "blob_build.test.Aromanian ",
        "blob_build.test.DV ",
        "blob_build.test.Estonian ",
        "blob_build.test.Figure ",
        "blob_build.test.Finnish ",
        "blob_build.test.GN ",
        "blob_build.test.GOR ",
        "blob_build.test.HU ",
        "blob_build.test.IU ",
        "blob_build.test.InvalidPreContext ",
        "blob_build.test.Jezik ",
        "blob_build.test.KBD ",
        "blob_build.test.KL ",
        "blob_build.test.KU ",
        "blob_build.test.KY ",
        "blob_build.test.LT ",
        "blob_build.test.Latin ",
        "blob_build.test.MG ",
        "blob_build.test.RU ",
        "blob_build.test.Ready ",
        "blob_build.test.RenderLimit ",
        "blob_build.test.SIMPLE ",
        "blob_build.test.SL ",
        "blob_build.test.SS ",
        "blob_build.test.Samoan ",
        "blob_build.test.Sanskrit ",
        "blob_build.test.TE ",
        "blob_build.test.TN ",
        "blob_build.test.TPI ",
        "blob_build.test.TT ",
        "blob_build.test.Tsonga ",
        "blob_build.test.UncompiledTemplate ",
        "blob_build.test.Writer ",
        "blob_build.test.Yiddish ",
        "blob_build.test.ZA ",
        "blob_build.test.Zulu ",
        "blob_build.test.absent ",
        "blob_build.test.acknowledged ",
        "blob_build.test.actual ",
        "blob_build.test.audit ",
        "blob_build.test.blob ",
        "blob_build.test.captured ",
        "blob_build.test.complete ",
        "blob_build.test.continuous ",
        "blob_build.test.conversion ",
        "blob_build.test.diagnostic ",
        "blob_build.test.existing ",
        "blob_build.test.explicit ",
        "blob_build.test.failed ",
        "blob_build.test.fatal ",
        "blob_build.test.first ",
        "blob_build.test.flattened ",
        "blob_build.test.heading ",
        "blob_build.test.headword ",
        "blob_build.test.indexed ",
        "blob_build.test.language ",
        "blob_build.test.literal ",
        "blob_build.test.localized ",
        "blob_build.test.missing ",
        "blob_build.test.named ",
        "blob_build.test.native ",
        "blob_build.test.official ",
        "blob_build.test.operational ",
        "blob_build.test.ordinary ",
        "blob_build.test.page ",
        "blob_build.test.parent ",
        "blob_build.test.prepared ",
        "blob_build.test.presentation ",
        "blob_build.test.project ",
        "blob_build.test.retained ",
        "blob_build.test.reviewed ",
        "blob_build.test.root ",
        "blob_build.test.selected ",
        "blob_build.test.sharded ",
        "blob_build.test.shared ",
        "blob_build.test.site ",
        "blob_build.test.source ",
        "blob_build.test.source-equivalent ",
        "blob_build.test.static ",
        "blob_build.test.test ",
        "blob_build.test.valid ",
        "blob_build.test.worker ",
    } },
    .{ .group = .tools_observations, .filters = &.{
        "figure_page_observations.test",
    } },
    .{ .group = .tools_support, .filters = &.{
        "expansion_deadline.test",
        "bundle_expander.test",
        "page_source_context.test",
        "source_internal_link.test",
        "page_language.test",
        "page_language_prefix.test",
        "source_title_variant.test",
        "source_table_styles.test",
        "source_stylesheet_imports.test",
        "source_default_gadgets.test",
        "language_registry.test",
        "reviewed_nonlexical.test",
        "figure_sizing.test",
        "figure_raw_gzip.test",
        "blob_build.test_",
    } },
};

const tools_test_files = [_][]const u8{
    "compiler/tools/blob_build.zig",
    "compiler/tools/figure_page_observations.zig",
    "compiler/tools/expansion_deadline.zig",
    "compiler/tools/bundle_expander.zig",
    "compiler/tools/page_source_context.zig",
    "compiler/tools/source_internal_link.zig",
    "compiler/tools/page_language.zig",
    "compiler/tools/page_language_prefix.zig",
    "compiler/tools/source_title_variant.zig",
    "compiler/tools/source_table_styles.zig",
    "compiler/tools/source_stylesheet_imports.zig",
    "compiler/tools/source_default_gadgets.zig",
    "compiler/tools/language_registry.zig",
    "compiler/tools/reviewed_nonlexical.zig",
    "compiler/tools/figure_sizing.zig",
    "compiler/tools/figure_raw_gzip.zig",
};

fn isToolsPartition(group: PreparedTestGroup) bool {
    return switch (group) {
        .tools_normal, .tools_core, .tools_observations, .tools_support => true,
        else => false,
    };
}

fn toolsPartitionForName(name: []const u8) !usize {
    var selected: ?usize = null;
    for (tools_partitions, 0..) |partition, i| {
        var found = false;
        for (partition.filters) |filter| found = found or std.mem.indexOf(u8, name, filter) != null;
        if (!found) continue;
        if (selected != null) return error.OverlappingToolsTestPartitions;
        selected = i;
    }
    return selected orelse error.UnmappedToolsTestName;
}

fn validateToolsTestSource(a: std.mem.Allocator, source: [:0]const u8, namespace: []const u8) !usize {
    var tokenizer: std.zig.Tokenizer = .init(source);
    var depth: usize = 0;
    var count: usize = 0;
    var anonymous: usize = 0;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(a);
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .invalid => return error.InvalidToolsTestSource,
            .l_brace => depth += 1,
            .r_brace => depth = std.math.sub(usize, depth, 1) catch return error.InvalidToolsTestSource,
            .keyword_test => {
                if (depth != 0) return error.NestedToolsTestRequiresPartition;
                const name_token = tokenizer.next();
                const name = if (name_token.tag == .l_brace) name: {
                    depth += 1;
                    const generated = try std.fmt.allocPrint(a, "{s}.test_{d}", .{ namespace, anonymous });
                    anonymous += 1;
                    break :name generated;
                } else name: {
                    if (name_token.tag != .string_literal) return error.InvalidToolsTestSource;
                    const decoded = try std.zig.string_literal.parseAlloc(a, source[name_token.loc.start..name_token.loc.end]);
                    break :name try std.fmt.allocPrint(a, "{s}.test.{s}", .{ namespace, decoded });
                };
                if ((try names.getOrPut(a, name)).found_existing) return error.DuplicateToolsTestName;
                _ = toolsPartitionForName(name) catch |err| {
                    std.debug.print("unassigned or overlapping Tools test: {s} ({s})\n", .{ name, @errorName(err) });
                    return err;
                };
                count += 1;
            },
            else => {},
        }
    }
    if (depth != 0) return error.InvalidToolsTestSource;
    return count;
}

test "Tools partition source inventory" {
    inline for (tools_test_files) |relative| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const source = @embedFile(relative);
        if (source.len > 16 * 1024 * 1024) return error.ToolsTestSourceTooLarge;
        const count = validateToolsTestSource(arena.allocator(), source, std.fs.path.stem(relative)) catch |err| {
            std.debug.print("{s}: invalid Tools test partition boundary: {s}\n", .{ relative, @errorName(err) });
            return err;
        };
        if (count == 0) {
            std.debug.print("{s}: empty Tools test namespace\n", .{relative});
            return error.EmptyToolsTestNamespace;
        }
    }
}

test "Tools partitions cover exact decoded names and retain unnamed controls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "// test \"ignored\" {}\nconst text = \"test\";\ntest \"normal Writer check\" {}\ntest \"normal Writer check extra\" {}\ntest \"presentation quote \\\" and \\u{e9}\" {}\ntest {}\n";
    try std.testing.expectEqual(@as(usize, 4), try validateToolsTestSource(arena.allocator(), source, "blob_build"));
    try std.testing.expectEqual(@as(usize, 0), try toolsPartitionForName("blob_build.test.normal Writer check"));
    try std.testing.expectEqual(@as(usize, 0), try toolsPartitionForName("blob_build.test.normal Writer check extra"));
    try std.testing.expectEqual(@as(usize, 3), try toolsPartitionForName("blob_build.test_0"));
    try std.testing.expectError(error.UnmappedToolsTestName, toolsPartitionForName("blob_build.test.new-family check"));
}

test "Tools partitions refuse malformed duplicate or nested declarations without dropping them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NestedToolsTestRequiresPartition, validateToolsTestSource(arena.allocator(), "const S = struct { test \"nested\" {} };", "blob_build"));
    try std.testing.expectError(error.DuplicateToolsTestName, validateToolsTestSource(arena.allocator(), "test \"presentation same\" {} test \"presentation same\" {}", "blob_build"));
    try std.testing.expectError(error.InvalidToolsTestSource, validateToolsTestSource(arena.allocator(), "test 1 {}", "blob_build"));
}


test "Tools partitions preserve legacy focused selection and reject OR overrides" {
    for (std.meta.tags(PreparedTestGroup)) |group| {
        try std.testing.expectEqual(isToolsPartition(group), preparedTestGroupIncluded(.tools_partitioned, group));
        try std.testing.expectEqual(group == .tools, preparedTestGroupIncluded(.tools, group));
    }
    for (tools_partitions) |partition| {
        try std.testing.expect(preparedTestGroupIncluded(partition.group, partition.group));
        try std.testing.expectError(error.ToolsPartitionFilterNotSupported, preparedTestFilters(std.testing.allocator, partition.group, &.{"one"}));
    }
    try std.testing.expectError(error.ToolsPartitionFilterNotSupported, preparedTestFilters(std.testing.allocator, .tools_partitioned, &.{"one"}));
}

fn toolsPartitionFilters(group: PreparedTestGroup) []const []const u8 {
    for (tools_partitions) |partition| if (partition.group == group) return partition.filters;
    unreachable;
}

test "Tools normal full and focused selection retain their distinct contracts" {
    for (std.meta.tags(PreparedTestGroup)) |group| {
        try std.testing.expectEqual(isToolsPartition(group), preparedTestGroupIncluded(.tools_partitioned, group));
        try std.testing.expectEqual(group == .tools, preparedTestGroupIncluded(.tools, group));
    }
    try std.testing.expect(!preparedTestGroupIncluded(null, .tools));
    try std.testing.expect(preparedTestGroupIncluded(null, .tools_support));
    try std.testing.expectEqualStrings("blob_build.test_", tools_partitions[3].filters[tools_partitions[3].filters.len - 1]);
    const filters = try preparedTestFilters(std.testing.allocator, .tools, &.{"one"});
    defer std.testing.allocator.free(filters);
    try std.testing.expectEqualStrings("one", filters[0]);
}

fn addToolsRunObligation(aggregate: *std.Build.Step, run: *std.Build.Step,
    preceding: *std.Build.Step, following: *std.Build.Step, memory_claims: bool) void
{
    addTestOrder(aggregate, run, preceding, memory_claims);
    aggregate.dependOn(run);
    addTestOrder(aggregate, following, run, memory_claims);
}

test "Tools full graph keeps failed partitions independent and preserves normal memory ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b: std.Build = undefined;
    b.allocator = arena.allocator();
    for ([_]bool{ false, true }) |memory_claims| {
        var root: std.Build.Step = undefined;
        var preceding: std.Build.Step = undefined;
        var following: std.Build.Step = undefined;
        for ([_]*std.Build.Step{ &root, &preceding, &following }) |step| {
            step.owner = &b;
            step.dependencies = .empty;
        }
        var runs: [4]std.Build.Step = undefined;
        var compiles: [4]std.Build.Step = undefined;
        root.dependOn(&following);
        for (&runs, &compiles) |*run, *compiled| {
            run.owner = &b;
            run.dependencies = .empty;
            compiled.owner = &b;
            compiled.dependencies = .empty;
            run.dependOn(compiled);
            addToolsRunObligation(&root, run, &preceding, &following, memory_claims);
        }
        for (&runs, &compiles) |*run, *compiled| {
            try std.testing.expect(std.mem.indexOfScalar(*std.Build.Step, root.dependencies.items, run) != null);
            try std.testing.expect(std.mem.indexOfScalar(*std.Build.Step, run.dependencies.items, compiled) != null);
            for (&runs) |*sibling| {
                if (sibling == run) continue;
                try std.testing.expect(std.mem.indexOfScalar(*std.Build.Step, run.dependencies.items, sibling) == null);
            }
            try std.testing.expectEqual(!memory_claims, std.mem.indexOfScalar(*std.Build.Step, run.dependencies.items, &preceding) != null);
            try std.testing.expectEqual(!memory_claims, std.mem.indexOfScalar(*std.Build.Step, following.dependencies.items, run) != null);
        }
    }
}
