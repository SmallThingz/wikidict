const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const structure_optimize: std.builtin.OptimizeMode = .ReleaseFast;

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
    const encoder_mod_structure = b.addModule("encoder_structure", .{
        .root_source_file = b.path("encoder/root.zig"),
        .target = target,
        .optimize = structure_optimize,
    });
    encoder_mod_structure.addImport("zxml", zxml_dep_structure.module("zxml"));

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

    b.installArtifact(encoder_exe);
    b.installArtifact(decoder_exe);
    b.installArtifact(backend_exe);
    b.installArtifact(structure_exe);

    addRunStep(b, "encode", "Run the encoder CLI", encoder_exe, &.{});
    addRunStep(b, "decode", "Run the decoder CLI", decoder_exe, &.{});
    addRunStep(b, "serve", "Run the backend server", backend_exe, &.{});
    addRunStep(b, "structure", "Analyze Wiktionary structure", structure_exe, &.{});

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

    const run_encoder_tests = b.addRunArtifact(encoder_tests);
    const run_decoder_tests = b.addRunArtifact(decoder_tests);
    const run_backend_tests = b.addRunArtifact(backend_tests);
    const run_structure_tests = b.addRunArtifact(structure_tests);

    const test_step = b.step("test", "Run encoder, decoder, and backend tests");
    test_step.dependOn(&run_encoder_tests.step);
    test_step.dependOn(&run_decoder_tests.step);
    test_step.dependOn(&run_backend_tests.step);
    test_step.dependOn(&run_structure_tests.step);
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
