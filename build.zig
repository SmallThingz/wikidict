const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zxml_dep = b.dependency("zxml", .{
        .target = target,
        .optimize = optimize,
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

    b.installArtifact(encoder_exe);
    b.installArtifact(decoder_exe);
    b.installArtifact(backend_exe);

    addRunStep(b, "encode", "Run the encoder CLI", encoder_exe, &.{});
    addRunStep(b, "lookup", "Run a decoder lookup", decoder_exe, &.{"lookup"});
    addRunStep(b, "suggest", "Run decoder suggestions", decoder_exe, &.{"suggest"});
    addRunStep(b, "stats", "Show decoder statistics", decoder_exe, &.{"stats"});
    addRunStep(b, "serve", "Run the backend server", backend_exe, &.{});

    addFrontendStep(b, "frontend-install", "Install frontend dependencies", &.{ "bun", "install" }, false);
    addFrontendStep(b, "frontend-build", "Build the frontend", &.{ "bun", "run", "build" }, true);
    addFrontendStep(b, "frontend-check", "Type-check and build the frontend", &.{ "bun", "run", "check" }, true);
    addFrontendStep(b, "frontend-dev", "Run the frontend dev server", &.{ "bun", "run", "dev" }, true);
    addFrontendStep(b, "frontend-preview", "Preview the built frontend", &.{ "bun", "run", "start" }, true);

    const encoder_tests = b.addTest(.{ .root_module = encoder_mod });
    const decoder_tests = b.addTest(.{ .root_module = decoder_mod });
    const backend_tests = b.addTest(.{ .root_module = backend_mod });

    const run_encoder_tests = b.addRunArtifact(encoder_tests);
    const run_decoder_tests = b.addRunArtifact(decoder_tests);
    const run_backend_tests = b.addRunArtifact(backend_tests);

    const test_step = b.step("test", "Run encoder, decoder, and backend tests");
    test_step.dependOn(&run_encoder_tests.step);
    test_step.dependOn(&run_decoder_tests.step);
    test_step.dependOn(&run_backend_tests.step);
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

fn addFrontendStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    argv: []const []const u8,
    depends_on_install: bool,
) void {
    const cmd = b.addSystemCommand(argv);
    cmd.setCwd(b.path("frontend"));

    if (depends_on_install) {
        const install_cmd = b.addSystemCommand(&.{ "bun", "install" });
        install_cmd.setCwd(b.path("frontend"));
        cmd.step.dependOn(&install_cmd.step);
    }

    const step = b.step(name, description);
    step.dependOn(&cmd.step);
}
