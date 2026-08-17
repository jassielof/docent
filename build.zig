const std = @import("std");

const fangz_build = @import("fangz");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fangz_mod = b.dependency("fangz", .{
        .target = target,
        .optimize = optimize,
    }).module("fangz");
    const carnaval_mod = b.dependency("carnaval", .{
        .target = target,
        .optimize = optimize,
    }).module("carnaval");
    const toml_mod = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    }).module("toml");
    const dmp_mod = b.dependency("dmp", .{
        .target = target,
        .optimize = optimize,
    }).module("dmp");

    const doc_comment_mod = b.addModule("doc_comment", .{
        .root_source_file = b.path("lib/doc_comment/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const identifier_style_mod = b.addModule("identifier_style", .{
        .root_source_file = b.path("lib/identifier_style/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fmt_mod = b.addModule("fmt", .{
        .root_source_file = b.path("lib/fmt/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "carnaval", .module = carnaval_mod },
            .{ .name = "dmp", .module = dmp_mod },
        },
    });

    // Shared types used by independently consumable lint-rule modules.
    const lint_mod = b.addModule("lint", .{
        .root_source_file = b.path("lib/lint/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cogni_mod = b.addModule("cogni", .{
        .root_source_file = b.path("lib/cogni/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lint", .module = lint_mod }},
    });

    const cyclo_mod = b.addModule("cyclo", .{
        .root_source_file = b.path("lib/cyclo/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lint", .module = lint_mod }},
    });

    // The reusable rule-checking engine aggregates independently-owned checks and their
    // configuration. It depends on `cogni` and `cyclo`; neither complexity module depends on it.
    const rules_mod = b.addModule("rules", .{
        .root_source_file = b.path("lib/rules/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "doc_comment", .module = doc_comment_mod },
            .{ .name = "identifier_style", .module = identifier_style_mod },
            .{ .name = "lint", .module = lint_mod },
            .{ .name = "cogni", .module = cogni_mod },
            .{ .name = "cyclo", .module = cyclo_mod },
        },
    });

    // Discovers which files/build targets a project-wide operation (the CLI, `typeset`) should
    // operate over: build.zig target parsing, CLI target-selection filtering, import-graph
    // reachability. Public so `typeset` can depend on just this instead of all of `docent`.
    const project_scan_mod = b.addModule("project_scan", .{
        .root_source_file = b.path("lib/project_scan/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "carnaval", .module = carnaval_mod },
        },
    });

    const typeset_mod = b.addModule("typeset", .{
        .root_source_file = b.path("lib/typeset/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "doc_comment", .module = doc_comment_mod },
            .{ .name = "project_scan", .module = project_scan_mod },
        },
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("internal/docent/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "carnaval", .module = carnaval_mod },
            .{ .name = "fangz", .module = fangz_mod },
            .{ .name = "toml", .module = toml_mod },
            .{ .name = "doc_comment", .module = doc_comment_mod },
            .{ .name = "fmt", .module = fmt_mod },
            .{ .name = "identifier_style", .module = identifier_style_mod },
            .{ .name = "rules", .module = rules_mod },
            .{ .name = "cogni", .module = cogni_mod },
            .{ .name = "cyclo", .module = cyclo_mod },
            .{ .name = "project_scan", .module = project_scan_mod },
        },
    });

    const docs_lib = b.addLibrary(.{
        .name = "docent",
        .root_module = mod,
    });

    const cli_step = b.step("docent", "Run the CLI");

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("cmd/docent/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "docent", .module = mod },
            .{ .name = "fangz", .module = fangz_mod },
            .{ .name = "carnaval", .module = carnaval_mod },
            .{ .name = "toml", .module = toml_mod },
            .{ .name = "typeset", .module = typeset_mod },
            .{ .name = "doc_comment", .module = doc_comment_mod },
            .{ .name = "fmt", .module = fmt_mod },
        },
    });

    const cli = b.addExecutable(.{
        .name = "docent",
        // Add exectuable can take a version field, so that should be used for the metadata injection, IF IT'S AVAILABLE, in my case I simply won't use it, so it should fallback to the build.zig.zon version field instead. In the case where the user uses the version here from addExecutable, it's a SemanticVersion type.
        // .version =
        .root_module = cli_mod,
    });

    // Inject the executable name from addExecutable(), the executable/manifest version, and git metadata so App.init can infer runtime and docs metadata.
    fangz_build.injectMetadata(b, cli, fangz_mod);

    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());

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
    docs_cli.step.dependOn(b.getInstallStep());
    docs_cli.addArgs(&.{
        "docs",
        "--output-dir",
        "zig-out/docs/cli/",
    });

    docs_step.dependOn(&docs_cli.step);

    // `zig build docs-pdf` discovers every module in this package (the
    // `docent` library plus the `docent` CLI executable, via the same
    // build.zig target discovery `docent status`/`docent check` use),
    // follows every `pub const X = @import(...)` re-export transitively
    // within each, emits one docs.json covering all of them, and renders it
    // to a single PDF via the local `docent-docs` Typst package. See
    // modules/typeset.zig and typst/docent-docs/.
    //
    // Default is primary targets only (no --deps / --bundle-std) to keep
    // PDF size bounded; pass those flags to `docent typeset` for appendix
    // fidelity when needed.
    const docs_pdf_step = b.step("docs-pdf", "Generate PDF documentation for docent's modules via Typst");

    const typeset_json_path = "zig-out/docs/typeset/docs.json";

    const typeset_cli = b.addRunArtifact(cli);
    typeset_cli.step.dependOn(b.getInstallStep());
    typeset_cli.addArgs(&.{
        "typeset",
        "--lib",
        "--bins",
        "--output",
        typeset_json_path,
    });

    const typst_compile = b.addSystemCommand(&.{
        "typst",
        "compile",
        "--pdf-standard",
        "2.0",
        "--root",
        ".",
        "--input",
        // Leading "/" resolves relative to --root, not to lib.typ's directory.
        b.fmt("docs-json=/{s}", .{typeset_json_path}),
        "typst/docent-docs/lib.typ",
        "zig-out/docs/typeset/docent.pdf",
    });
    typst_compile.step.dependOn(&typeset_cli.step);

    docs_pdf_step.dependOn(&typst_compile.step);

    const test_step = b.step("test", "Run the test suite");

    const docent_lib_tests = b.addTest(.{
        .name = "Docent",
        .root_module = mod,
    });

    const run_docent_lib_tests = b.addRunArtifact(docent_lib_tests);
    test_step.dependOn(&run_docent_lib_tests.step);

    const rules_lib_tests = b.addTest(.{
        .name = "Rules",
        .root_module = rules_mod,
    });

    const run_rules_lib_tests = b.addRunArtifact(rules_lib_tests);
    test_step.dependOn(&run_rules_lib_tests.step);

    const cogni_lib_tests = b.addTest(.{ .name = "Cognitive Complexity", .root_module = cogni_mod });
    test_step.dependOn(&b.addRunArtifact(cogni_lib_tests).step);
    const cyclo_lib_tests = b.addTest(.{ .name = "Cyclomatic Complexity", .root_module = cyclo_mod });
    test_step.dependOn(&b.addRunArtifact(cyclo_lib_tests).step);

    const project_scan_lib_tests = b.addTest(.{
        .name = "Project Scan",
        .root_module = project_scan_mod,
    });

    const run_project_scan_lib_tests = b.addRunArtifact(project_scan_lib_tests);
    test_step.dependOn(&run_project_scan_lib_tests.step);

    const identifier_style_lib_tests = b.addTest(.{
        .name = "Identifier Style",
        .root_module = identifier_style_mod,
    });

    const run_identifier_style_lib_tests = b.addRunArtifact(identifier_style_lib_tests);
    test_step.dependOn(&run_identifier_style_lib_tests.step);

    const fmt_lib_tests = b.addTest(.{
        .name = "Formatting",
        .root_module = fmt_mod,
    });

    const run_fmt_lib_tests = b.addRunArtifact(fmt_lib_tests);
    test_step.dependOn(&run_fmt_lib_tests.step);

    const doc_comment_lib_tests = b.addTest(.{
        .name = "Doc Comments",
        .root_module = doc_comment_mod,
    });

    const run_doc_comment_lib_tests = b.addRunArtifact(doc_comment_lib_tests);
    test_step.dependOn(&run_doc_comment_lib_tests.step);

    const integration_tests = b.addTest(.{
        .name = "Integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "docent", .module = mod },
                .{ .name = "fangz", .module = fangz_mod },
                .{ .name = "carnaval", .module = carnaval_mod },
                .{ .name = "cli", .module = cli_mod },
                .{ .name = "fmt", .module = fmt_mod },
                .{ .name = "identifier_style", .module = identifier_style_mod },
            },
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);

    const schema_step = b.step("schema", "Generate JSON schema from YAML");
    const yq_cli = b.addSystemCommand(&.{"yq"});
    yq_cli.addArgs(&.{ "--output-format", "json" });
    yq_cli.addFileArg(b.path("schemas/docent.schema.yaml"));
    const schema_json = yq_cli.captureStdOut(.{});
    const install_schema = b.addInstallFile(schema_json, "schema/docent.schema.json");
    schema_step.dependOn(&install_schema.step);
    b.getInstallStep().dependOn(schema_step);

    const check_step = b.step("check", "Run code quality checks");

    const fmt = b.addFmt(.{
        .check = true,
        .paths = &.{
            "cmd/",
            "lib/",
            "internal/",
        },
    });
    check_step.dependOn(&fmt.step);

    const all_checks = b.addRunArtifact(cli);
    all_checks.step.dependOn(b.getInstallStep());
    all_checks.addArgs(&.{
        "check",
        "all",
        "--deps",
        "--format",
        "minimal",
        "--fail-fast",
        "any",
    });
    check_step.dependOn(&all_checks.step);
}
