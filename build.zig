const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod_name = "doclint";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fangz = b.dependency("fangz", .{}).module("fangz");

    const lib_mod = b.addModule(mod_name, .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = mod_name,
        .root_module = lib_mod,
    });

    const cli = b.addExecutable(.{
        .name = mod_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = mod_name,
                    .module = lib_mod,
                },
                .{
                    .name = "fangz",
                    .module = fangz,
                },
            },
        }),
    });

    b.installArtifact(cli);
    const cli_step = b.step("cli", "Run the CLI");

    const run_cli = b.addRunArtifact(cli);
    cli_step.dependOn(&run_cli.step);

    run_cli.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cli.addArgs(args);
    }

    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate the documentation");
    docs_step.dependOn(&docs.step);

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const suite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = mod_name,
                .module = lib_mod,
            }},
        }),
    });

    const test_step = b.step("tests", "Run the test suite");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(suite_tests).step);
}
