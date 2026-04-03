const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zxml_dep = b.dependency("zxml", .{
        .target = target,
        .optimize = optimize,
    });

    const dict_mod = b.addModule("dict", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    dict_mod.addImport("zxml", zxml_dep.module("zxml"));

    const exe = b.addExecutable(.{
        .name = "dict",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dict", .module = dict_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the dictionary CLI");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = dict_mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    if (b.args) |args| run_mod_tests.addArgs(args);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_mod_tests.step);
}
