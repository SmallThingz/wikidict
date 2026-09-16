const std = @import("std");

pub fn build(b: *std.Build) void {
    b.graph.incremental = false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSafe;
    const test_optimize: std.builtin.OptimizeMode = .ReleaseSafe;
    const zxml_dep = b.dependency("zxml", .{
        .target = target,
        .optimize = optimize,
    });
    const zxml_dep_test = b.dependency("zxml", .{
        .target = target,
        .optimize = test_optimize,
    });
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
    const storage_mod = b.createModule(.{ .root_source_file = b.path("src/native/storage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod }} });
    storage_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    const storage_test = b.createModule(.{ .root_source_file = b.path("src/native/storage.zig"), .target = target, .optimize = test_optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod_test }} });
    storage_test.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    const encoder_mod = b.addModule("encoder", .{
        .root_source_file = b.path("src/encoder/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    encoder_mod.addImport("shared_xml_decode", shared_xml_decode_mod);
    encoder_mod.addImport("blob_encoder", blob_encoder_mod);

    const encoder_mod_test = b.addModule("encoder_test", .{
        .root_source_file = b.path("src/encoder/root.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    encoder_mod_test.addImport("shared_xml_decode", shared_xml_decode_mod_test);
    encoder_mod_test.addImport("blob_encoder", blob_encoder_mod_test);

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

    const module_extract_exe = addCliExecutable(b, "dict-module-extract", b.path("src/lua/module_extract_main.zig"), target, optimize, &.{
        .{ .name = "zxml", .module = zxml_dep.module("zxml") },
        .{ .name = "xml_decode", .module = shared_xml_decode_mod },
    });
    const blob_build_exe = addCliExecutable(b, "dict-blob-build", b.path("tools/blob_build.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = encoder_mod },
        .{ .name = "zxml", .module = zxml_dep.module("zxml") },
        .{ .name = "xml_decode", .module = shared_xml_decode_mod },
    });
    const blob_verify_exe = addCliExecutable(b, "dict-blob-verify", b.path("tools/blob_verify.zig"), target, optimize, &.{
        .{ .name = "encoder", .module = encoder_mod },
    });

    const llvm_exe = addCliExecutable(b, "dict-llvm-build", b.path("src/lua/llvm_build_main.zig"), target, optimize, &.{});
    addPublicRunStep(b, "compile-lua", "Compile extracted Lua AST directly to LLVM IR", addRunArtifactCommand(b, llvm_exe, &.{}, b.args), &.{});
    const pipeline_paths = b.addOptions();
    pipeline_paths.addOptionPath("modules", module_extract_exe.getEmittedBin());
    pipeline_paths.addOptionPath("llvm", llvm_exe.getEmittedBin());
    pipeline_paths.addOption([]const u8, "zig", b.graph.zig_exe);
    pipeline_paths.addOption([]const u8, "project_root", b.pathFromRoot("."));
    pipeline_paths.addOptionPath("blobs", blob_build_exe.getEmittedBin());
    const pipeline_exe = addCliExecutable(b, "dict-bundle-build", b.path("tools/bundle_build.zig"), target, optimize, &.{.{ .name = "pipeline_paths", .module = pipeline_paths.createModule() }});
    addPublicRunStep(b, "build-dictionary", "Pre-expand templates/modules and emit data-only dictionary blobs", addRunArtifactCommand(b, pipeline_exe, &.{}, b.args), &.{});
    const blob_files_mod = b.createModule(.{ .root_source_file = b.path("src/encoder/blob_files.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod }} });
    const blob_files_mod_test = b.createModule(.{ .root_source_file = b.path("src/encoder/blob_files.zig"), .target = target, .optimize = test_optimize, .imports = &.{.{ .name = "blob_encoder", .module = blob_encoder_mod_test }} });
    const blob_query_exe = addCliExecutable(b, "dict", b.path("src/frontend/main.zig"), target, optimize, &.{
        .{ .name = "blob_encoder", .module = blob_encoder_mod },
        .{ .name = "blob_decoder", .module = blob_decoder_mod },
        .{ .name = "blob_files", .module = blob_files_mod },
        .{ .name = "blob_storage", .module = storage_mod },
        .{ .name = "html_entities", .module = b.createModule(.{ .root_source_file = b.path("src/shared/html_entities.zig"), .target = target, .optimize = optimize }) },
    });
    // Locale-aware terminal cell widths use libc; lld supports current host crt objects.
    blob_query_exe.root_module.link_libc = true;
    blob_query_exe.use_llvm = true;
    blob_query_exe.use_lld = true;
    b.installArtifact(blob_query_exe);

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
            .{ .name = "html_entities", .module = b.createModule(.{ .root_source_file = b.path("src/shared/html_entities.zig"), .target = target, .optimize = optimize }) },
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

    const module_extract_run = addRunArtifactCommand(b, module_extract_exe, &.{}, b.args);
    addPublicRunStep(b, "extract-modules", "Extract Scribunto modules from a Wiktionary XML dump", module_extract_run, &.{});

    const blob_verify_run = addRunArtifactCommand(b, blob_verify_exe, &.{}, b.args);
    addPublicRunStep(b, "verify-blobs", "Verify compiled blob framing and presentation records", blob_verify_run, &.{});

    const blob_query_run = addRunArtifactCommand(b, blob_query_exe, &.{}, b.args);
    addPublicRunStep(b, "query-blobs", "Query per-language and feature Wiktionary blobs", blob_query_run, &.{});
    addPublicRunStep(b, "dict", "Run the dictionary frontend CLI", blob_query_run, &.{});

    const qt_configure = b.addSystemCommand(&.{ "cmake", "-S", "src/qt", "-B", ".zig-cache/qt", "-DCMAKE_BUILD_TYPE=Release" });
    qt_configure.step.dependOn(&ffi_install.step);
    qt_configure.step.dependOn(&ffi_header_install.step);
    const qt_build = b.addSystemCommand(&.{ "cmake", "--build", ".zig-cache/qt", "--target", "dict-qt", "--parallel", "2" });
    qt_build.step.dependOn(&qt_configure.step);
    b.step("qt", "Build the Qt 6 C++ desktop frontend").dependOn(&qt_build.step);
    b.step("frontend", "Build the Qt 6 C++ desktop frontend").dependOn(&qt_build.step);

    const test_runner = b.path("tools/test_runner.zig");

    const encoder_tests = b.addTest(.{
        .root_module = encoder_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const blob_encoder_tests = b.addTest(.{
        .root_module = blob_encoder_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const blob_decoder_tests = b.addTest(.{
        .root_module = blob_decoder_mod_test,
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const blob_query_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontend/main.zig"),
            .target = target,
            .optimize = test_optimize,
            .imports = &.{
                .{ .name = "blob_encoder", .module = blob_encoder_mod_test },
                .{ .name = "blob_decoder", .module = blob_decoder_mod_test },
                .{ .name = "blob_files", .module = blob_files_mod_test },
                .{ .name = "blob_storage", .module = storage_test },
                .{ .name = "html_entities", .module = b.createModule(.{ .root_source_file = b.path("src/shared/html_entities.zig"), .target = target, .optimize = test_optimize }) },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    blob_query_tests.root_module.link_libc = true;
    blob_query_tests.use_llvm = true;
    blob_query_tests.use_lld = true;
    const lua_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua/tests.zig"),
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
    const zig_runtime_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lua/runtime/core.zig"),
        .target = target,
        .optimize = test_optimize,
    });
    zig_runtime_test_mod.addImport("lua_static_fields", lua_static_fields_test_mod);
    const lua_stdlib_tests = b.addTest(.{
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
    });
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
                .{ .name = "lua_wikitext_preprocess", .module = lua_wikitext_preprocess_test_mod },
                .{ .name = "lua_wikitext_expression", .module = lua_wikitext_expression_test_mod },
            },
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const lua_wikitext_tests = b.addTest(.{
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
            },
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
    const run_blob_decoder_tests = b.addRunArtifact(blob_decoder_tests);
    const run_blob_query_tests = b.addRunArtifact(blob_query_tests);
    const run_lua_tests = b.addRunArtifact(lua_tests);
    const run_lua_stdlib_tests = b.addRunArtifact(lua_stdlib_tests);
    const run_lua_ustring_tests = b.addRunArtifact(lua_ustring_tests);
    const run_lua_scribunto_tests = b.addRunArtifact(lua_scribunto_tests);
    const run_lua_wikitext_tests = b.addRunArtifact(lua_wikitext_tests);

    blob_encoder_tests.step.dependOn(&run_encoder_tests.step);
    blob_decoder_tests.step.dependOn(&run_blob_encoder_tests.step);
    blob_query_tests.step.dependOn(&run_blob_decoder_tests.step);
    lua_tests.step.dependOn(&run_blob_query_tests.step);
    lua_stdlib_tests.step.dependOn(&run_lua_tests.step);
    lua_ustring_tests.step.dependOn(&run_lua_stdlib_tests.step);
    lua_scribunto_tests.step.dependOn(&run_lua_ustring_tests.step);
    lua_wikitext_tests.step.dependOn(&run_lua_scribunto_tests.step);

    const test_step = b.step("test", "Run bundle encoder, data reader, Lua, and tooling tests");
    blob_wasm_smoke.step.dependOn(&run_lua_wikitext_tests.step);
    test_step.dependOn(&blob_wasm_smoke.step);
    const media_fetch_exe = addCliExecutable(b, "dict-media-fetch", b.path("tools/media_fetch.zig"), target, optimize, &.{ .{ .name = "media_types", .module = b.createModule(.{ .root_source_file = b.path("src/frontend/media_types.zig"), .target = target, .optimize = optimize }) }, .{ .name = "shared_xml_decode", .module = shared_xml_decode_mod } });
    addPublicRunStep(b, "fetch-media", "Download bounded attributed Wikimedia assets for an export", addRunArtifactCommand(b, media_fetch_exe, &.{}, b.args), &.{});
    const bundle_test_exe = addCliExecutable(b, "dict-bundle-integration-test", b.path("tools/bundle_integration_test.zig"), b.graph.host, test_optimize, &.{});
    const bundle_test_run = b.addRunArtifact(bundle_test_exe);
    bundle_test_run.addFileArg(blob_query_exe.getEmittedBin());
    bundle_test_run.addFileArg(pipeline_exe.getEmittedBin());
    bundle_test_run.addFileArg(blob_verify_exe.getEmittedBin());
    bundle_test_run.addArg(b.pathFromRoot(".zig-cache"));
    b.step("test-bundle", "Exercise build-time Lua/template expansion into data-only blobs").dependOn(&bundle_test_run.step);
    const reader_test_exe = addCliExecutable(b, "dict-reader-integration-test", b.path("tools/reader_integration_test.zig"), b.graph.host, test_optimize, &.{.{ .name = "blob_encoder", .module = blob_encoder_mod_test }});
    const reader_test_run = b.addRunArtifact(reader_test_exe);
    reader_test_run.addFileArg(blob_query_exe.getEmittedBin());
    reader_test_run.addFileArg(ffi_test_exe.getEmittedBin());
    reader_test_run.addArg(b.pathFromRoot(".zig-cache"));
    b.step("test-reader", "Exercise precompiled data-only reading through CLI and C FFI").dependOn(&reader_test_run.step);
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
    if (target.result.os.tag == b.graph.host.result.os.tag and target.result.cpu.arch == b.graph.host.result.cpu.arch) test_step.dependOn(&storage_run.step);
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
