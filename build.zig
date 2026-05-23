const std = @import("std");

const fangz_build = @import("fangz");
const lizzy = @import("lizzy");

pub fn build(b: *std.Build) void {
    const mod_name = "docent";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fangz_mod = b.dependency("fangz", .{}).module("fangz");
    const vereda_mod = b.dependency("vereda", .{}).module("vereda");
    const carnaval_mod = b.dependency("carnaval", .{}).module("carnaval");

    const mod = b.addModule(
        mod_name,
        .{
            .root_source_file = b.path("src/lib/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "carnaval",
                    .module = carnaval_mod,
                },
                .{
                    .name = "vereda",
                    .module = vereda_mod,
                },
            },
        },
    );

    const docs_lib = b.addLibrary(.{
        .name = mod_name,
        .root_module = mod,
    });

    const cli_step = b.step("cli", "Run the CLI");

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = mod_name, .module = mod },
            .{ .name = "fangz", .module = fangz_mod },
            .{ .name = "carnaval", .module = carnaval_mod },
        },
    });

    const cli = b.addExecutable(.{
        .name = mod_name,
        // Add exectuable can take a version field, so that should be used for the metadata injection, IF IT'S AVAILABLE, in my case I simply won't use it, so it should fallback to the build.zig.zon version field instead. In the case where the user uses the version here from addExecutable, it's a SemanticVersion type.
        // .version =
        .root_module = cli_mod,
    });

    // Inject the executable name from addExecutable(), the executable/manifest version, and git metadata so App.init can infer runtime and docs metadata.
    fangz_build.injectMetadata(b, cli, fangz_mod);

    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    // run_cli.step.dependOn(b.getInstallStep());

    cli_step.dependOn(&run_cli.step);

    if (b.args) |args| run_cli.addArgs(args);

    const docs_step = b.step("docs", "Generate the documentation");

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/lib",
    });

    docs_step.dependOn(&install_docs.step);

    const docs_cli = b.addRunArtifact(cli);
    // docs_cli.step.dependOn(b.getInstallStep());
    docs_cli.addArgs(&.{
        "docs",
        "--output-dir",
        "zig-out/docs/cli/",
        "--file",
        "docent.adoc",
    });

    docs_step.dependOn(&docs_cli.step);

    const test_step = b.step("test", "Run the test suite");

    const unit_tests = b.addTest(.{
        .name = "Unit",
        .root_module = mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    const integration_tests = b.addTest(.{
        .name = "Integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = mod_name, .module = mod },
                .{ .name = "fangz", .module = fangz_mod },
                .{ .name = "carnaval", .module = carnaval_mod },
                .{ .name = "cli", .module = cli_mod },
            },
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);

    const check_step = b.step("check", "Run code quality checks");

    const lizzy_step = lizzy.addStepWithBuildOptions(b, .{});
    check_step.dependOn(lizzy_step);

    const fmt = b.addFmt(.{
        .check = true,
        .paths = &.{"src/"},
    });
    check_step.dependOn(&fmt.step);

    const docs_lint = b.addRunArtifact(cli);
    docs_lint.addArgs(&.{
        "--format",
        "minimal",
        "--fail-fast",
        "any",
    });
    check_step.dependOn(&docs_lint.step);
}
