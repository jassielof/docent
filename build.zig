const std = @import("std");
const scaffold = @import("src/lib/scaffold.zig");

pub fn build(b: *std.Build) void {
    const mod_name = "docent";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fangz = b.dependency("fangz", .{}).module("fangz");
    const vereda = b.dependency("vereda", .{}).module("vereda");
    const carnaval = b.dependency("carnaval", .{}).module("carnaval");

    const lib_mod = b.addModule(mod_name, .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "carnaval",
            .module = carnaval,
        }},
    });

    const docs_lib = b.addLibrary(.{
        .name = mod_name,
        .root_module = lib_mod,
    });

    const cli_step = b.step("cli", "Run the CLI");

    const cli = b.addExecutable(.{
        .name = mod_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{
                .name = mod_name,
                .module = lib_mod,
            }, .{
                .name = "fangz",
                .module = fangz,
            }, .{
                .name = "vereda",
                .module = vereda,
            } },
        }),
    });

    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    cli_step.dependOn(&run_cli.step);
    run_cli.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cli.addArgs(args);
    }

    const docs_step = b.step("docs", "Generate the documentation");

    const docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_lint = b.addRunArtifact(cli);
    docs_lint.addArgs(&.{});

    // const docs_lint = scaffold.addLintStep(b, .{
    //     .sources = &.{
    //         "src",
    //         "build.zig",
    //     },
    //     .rules = .{
    //         // Keep docs generation non-blocking on style gaps, like cargo doc.
    //         .missing_doc_comment = .warn,
    //         .empty_doc_comment = .warn,
    //         .missing_doctest = .warn,
    //         .private_doctest = .warn,
    //         .doctest_naming_mismatch = .warn,
    //         .missing_container_doc_comment = .warn,
    //     },
    // });

    // Lint must run before docs are generated/installed.
    docs.step.dependOn(&docs_lint.step);
    docs_step.dependOn(&docs.step);

    const test_step = b.step("tests", "Run the test suite");

    const unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    const integration_tests = b.addTest(.{
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

    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);
}
