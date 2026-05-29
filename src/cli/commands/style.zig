//! The style sub-command is in charge to report rules related about code style.
const std = @import("std");

const carnaval = @import("carnaval");
const docent = @import("docent");
const fangz = @import("fangz");

const cli_flags = @import("../flags.zig");

/// Registers the `style` sub-command on `root`.
pub fn register(root: *fangz.Command) !void {
    const style_cmd = try root.addSubcommand(.{
        .name = "style",
        .brief = "Report identifiers that don't follow the naming-case conventions",
        .description = "Check that every identifier (public and private) reachable from the project's module roots follows the Zig naming-case conventions (snake_case, camelCase, PascalCase). File discovery follows the public API surface, but within each file no visibility filter is applied. Severities are set in project config (.config/docent.json). Exits non-zero when a denied rule reports a finding.",
    });

    try style_cmd.addPositional(.{
        .name = "paths",
        .brief = "Files or directories to analyze. If omitted, uses package paths from build.zig.zon when available.",
        .variadic = true,
    });

    try cli_flags.registerConfigPath(style_cmd);

    try style_cmd.addFlag(bool, .{
        .name = "lib",
        .brief = "Analyze library targets only (default)",
        .default = false,
    });

    try style_cmd.addFlag(bool, .{
        .name = "bins",
        .brief = "Analyze all binary targets",
        .default = false,
    });

    try style_cmd.addFlag([]const []const u8, .{
        .name = "bin",
        .brief = "Analyze specific binary by name (repeatable)",
    });

    try style_cmd.addFlag(bool, .{
        .name = "tests",
        .brief = "Analyze all test targets",
        .default = false,
    });

    try style_cmd.addFlag([]const []const u8, .{
        .name = "test",
        .brief = "Analyze specific test by name (repeatable)",
    });

    try style_cmd.addFlag(bool, .{
        .name = "deps",
        .brief = "Also analyze files under path dependencies from build.zig.zon",
        .default = false,
    });

    try style_cmd.addFlag(bool, .{
        .name = "build-script",
        .brief = "Include build.zig and build/*.zig files in targets",
        .default = false,
    });

    style_cmd.setHooks(.{ .run = &run });
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

    // Style checks every declaration (public and private). File reachability still starts from the
    // module roots and follows the public API surface, but within each file no visibility filter is applied.
    const lint_options: docent.LintOptions = .{ .module_name = plan.package.name, .public_api_only = false };

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
        for (rt.files) |path| {
            const gptr = try analyzed_files.getOrPut(path);
            if (gptr.found_existing) continue;
            try analyzeFile(allocator, io, path, rule_set, lint_options, &all_diagnostics, &summary);
        }
    }

    for (plan.extra_lint_files) |path| {
        const gptr = try analyzed_files.getOrPut(path);
        if (gptr.found_existing) continue;
        try analyzeFile(allocator, io, path, rule_set, lint_options, &all_diagnostics, &summary);
    }

    const text_options = docent.output.stderrTextOptions(io, .pretty, .auto, path_display_root);
    try docent.output.printDiagnosticsStderr(io, all_diagnostics.items, text_options);
    const had_diagnostics = summary.errors > 0 or summary.warnings > 0;
    try docent.output.printSummaryStderr(io, summary, docent.output.stderrSummaryOptions(io, "docent style", .auto), had_diagnostics);

    if (summary.hasErrors()) std.process.exit(1);
}

fn analyzeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rule_set: docent.RuleSet,
    lint_options: docent.LintOptions,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
) !void {
    var result = docent.lintStyleFile(allocator, io, path, rule_set, lint_options) catch |err| {
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
