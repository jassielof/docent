//! The complexity sub-command is in charge to report related rules about complexity.
const std = @import("std");

const carnaval = @import("carnaval");
const docent = @import("docent");
const fangz = @import("fangz");

const cli_flags = @import("../flags.zig");

/// Registers the `complexity` sub-command on `root`.
pub fn register(root: *fangz.Command) !void {
    const complexity_cmd = try root.addSubcommand(.{
        .name = "complexity",
        .brief = "Report functions that exceed complexity thresholds",
        .description = "Measure the cognitive complexity of every function (public and private) reachable from the project's module roots and report those that exceed the configured threshold. Thresholds are set in project config (.config/docent.toml). Exits non-zero when a denied rule reports a finding.",
    });

    try complexity_cmd.addPositional(.{
        .name = "paths",
        .brief = "Files or directories to analyze. If omitted, uses package paths from build.zig.zon when available.",
        .variadic = true,
    });

    try cli_flags.registerConfigPath(complexity_cmd);

    try complexity_cmd.addFlag(bool, .{
        .name = "lib",
        .brief = "Analyze library targets only (default)",
        .default = false,
    });

    try complexity_cmd.addFlag(bool, .{
        .name = "bins",
        .brief = "Analyze all binary targets",
        .default = false,
    });

    try complexity_cmd.addFlag([]const []const u8, .{
        .name = "bin",
        .brief = "Analyze specific binary by name (repeatable)",
    });

    try complexity_cmd.addFlag(bool, .{
        .name = "tests",
        .brief = "Analyze all test targets",
        .default = false,
    });

    try complexity_cmd.addFlag([]const []const u8, .{
        .name = "test",
        .brief = "Analyze specific test by name (repeatable)",
    });

    try complexity_cmd.addFlag(bool, .{
        .name = "deps",
        .brief = "Also analyze files under path dependencies from build.zig.zon",
        .default = false,
    });

    try complexity_cmd.addFlag(bool, .{
        .name = "build-script",
        .brief = "Include build.zig and build/*.zig files in targets",
        .default = false,
    });

    complexity_cmd.setHooks(.{ .run = &run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const Args = struct {
        positionals: []const []const u8 = &.{},
        config_path: ?[]const u8 = null,
        lib: bool = false,
        bins: bool = false,
        bin: []const []const u8 = &.{},
        tests: bool = false,
        @"test": []const []const u8 = &.{},
        deps: bool = false,
        build_script: bool = false,
    };

    const args = try ctx.extract(Args);

    const rule_set = docent.config.loadRuleSetFromCli(allocator, io, args.config_path) catch |err| {
        try printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    const complexity_options = docent.config.loadComplexityOptionsFromCli(allocator, io, args.config_path) catch |err| {
        try printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    const complexity_public_api_only = docent.config.loadComplexityPublicApiOnlyFromCli(allocator, io, args.config_path) catch |err| {
        try printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    var plan = docent.status_plan.gather(allocator, io, .{
        .lib = args.lib,
        .bins = args.bins,
        .bin_names = args.bin,
        .tests = args.tests,
        .test_names = args.@"test",
        .deps = args.deps,
        .build_script = args.build_script,
        .positionals = args.positionals,
    }) catch |err| {
        try printStderr(io, "error: failed to build lint plan: {}\n", .{err});
        std.process.exit(1);
    };
    defer plan.deinit(allocator);

    const path_display_root = plan.package.project_root;

    // Complexity checks measure every declaration (public and private). File reachability still starts
    // from the module roots and follows the public API surface, but within each file no visibility
    // filter is applied.
    const lint_options: docent.LintOptions = .{
        .module_name = plan.package.name,
        .public_api_only = complexity_public_api_only,
    };

    var summary: docent.output.Summary = .{};
    var all_diagnostics: std.ArrayList(docent.Diagnostic) = .empty;
    defer {
        for (all_diagnostics.items) |d| docent.Diagnostic.deinitAlloc(d, allocator);
        all_diagnostics.deinit(allocator);
    }

    var analyzed_files = std.StringHashMap(void).init(allocator);
    defer analyzed_files.deinit();

    for (plan.resolved_targets) |rt| {
        if (rt.status != .linted) continue;

        const abs_root = if (std.fs.path.isAbsolute(rt.root_source_file))
            try allocator.dupe(u8, rt.root_source_file)
        else
            try std.fs.path.join(allocator, &.{ plan.package.project_root, rt.root_source_file });
        defer allocator.free(abs_root);

        var reachable = docent.reachability.collectReachableFiles(allocator, io, abs_root) catch |err| {
            try printStderr(io, "error: failed to resolve reachable files for '{s}': {}\n", .{ rt.root_source_file, err });
            continue;
        };
        defer docent.reachability.deinitOwnedPaths(allocator, &reachable);

        for (reachable.items) |path| {
            const gptr = try analyzed_files.getOrPut(path);
            if (gptr.found_existing) continue;
            try analyzeFile(allocator, io, path, rule_set, lint_options, complexity_options, &all_diagnostics, &summary);
        }
    }

    for (plan.extra_lint_files) |path| {
        const gptr = try analyzed_files.getOrPut(path);
        if (gptr.found_existing) continue;
        try analyzeFile(allocator, io, path, rule_set, lint_options, complexity_options, &all_diagnostics, &summary);
    }

    const text_options = docent.output.stderrTextOptions(io, .pretty, .auto, path_display_root);
    try docent.output.printDiagnosticsStderr(io, all_diagnostics.items, text_options);
    const had_diagnostics = summary.errors > 0 or summary.warnings > 0;
    try docent.output.printSummaryStderr(io, summary, docent.output.stderrSummaryOptions(io, "docent complexity", .auto), had_diagnostics);

    if (summary.hasErrors()) std.process.exit(1);
}

fn analyzeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rule_set: docent.RuleSet,
    lint_options: docent.LintOptions,
    complexity_options: docent.ComplexityOptions,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
) !void {
    var result = docent.lintComplexityFile(allocator, io, path, rule_set, lint_options, complexity_options) catch |err| {
        try printStderr(io, "error: failed to analyze '{s}': {}\n", .{ path, err });
        return;
    };
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        summary.observe(d);
        try all_diagnostics.append(allocator, try docent.Diagnostic.cloneAlloc(d, allocator));
    }
}

fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    try stderr.interface.print(fmt, args);
    try stderr.interface.flush();
}
