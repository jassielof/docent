//! `docent check complexity` — cognitive, cyclomatic, and parameter-count rules.

const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");

const cli_types = @import("../../types.zig");
const check_shared = @import("../../check_shared.zig");

pub fn register(check: *fangz.Command) !void {
    const complexity_cmd = try check.addSubcommand(.{
        .name = "complexity",
        .brief = "Check function complexity and parameter counts",
        .description = "Measure complexity and parameter counts for every function reachable from the project's module roots. Thresholds are set in project config (.config/docent.toml). Exits non-zero when a denied rule reports a finding.",
    });

    try check_shared.registerCategoryPositionals(complexity_cmd);
    try check_shared.registerOutputFlags(complexity_cmd);
    complexity_cmd.setHooks(.{ .run = &run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const args = try ctx.extract(check_shared.TargetArgs);

    const rule_set = docent.config.loadRuleSeveritiesFromCli(allocator, io, args.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    const complexity_options = docent.config.loadComplexityOptionsFromCli(allocator, io, args.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    var plan = check_shared.gatherPlan(allocator, io, args) catch |err| {
        try check_shared.printStderr(io, "error: failed to build lint plan: {}\n", .{err});
        std.process.exit(1);
    };
    defer plan.deinit(allocator);

    const path_display_root = try check_shared.allocPathDisplayRoot(allocator, io);
    defer allocator.free(path_display_root);

    var summary: docent.output.Summary = .{};
    var all_diagnostics: std.ArrayList(docent.Diagnostic) = .empty;
    defer {
        for (all_diagnostics.items) |d| docent.Diagnostic.deinitAlloc(d, allocator);
        all_diagnostics.deinit(allocator);
    }

    var analyzed_files = docent.targeting.PathSet.init(allocator);
    defer analyzed_files.deinit(allocator);

    _ = try analyzeReachableTargets(allocator, io, &plan, &analyzed_files, rule_set, complexity_options, &all_diagnostics, &summary, args.fail_fast);

    try check_shared.printCheckResults(io, allocator, args, "docent check complexity", all_diagnostics.items, summary, path_display_root);

    if (summary.hasErrors()) std.process.exit(1);
}

pub fn analyzeReachableTargets(
    allocator: std.mem.Allocator,
    io: std.Io,
    plan: *const docent.status_plan.Plan,
    analyzed_files: *docent.targeting.PathSet,
    rule_set: docent.RuleSeverities,
    complexity_options: docent.rules.complexity.Options,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    fail_fast: cli_types.FailFast,
) !bool {
    for (plan.resolved_targets) |rt| {
        if (rt.status != .linted) continue;

        const abs_root = if (std.fs.path.isAbsolute(rt.root_source_file))
            try allocator.dupe(u8, rt.root_source_file)
        else
            try std.fs.path.join(allocator, &.{ plan.package.project_root, rt.root_source_file });
        defer allocator.free(abs_root);

        var reachable = docent.reachability.collectReachableFiles(allocator, io, abs_root) catch |err| {
            try check_shared.printStderr(io, "error: failed to resolve reachable files for '{s}': {}\n", .{ rt.root_source_file, err });
            continue;
        };
        defer docent.reachability.deinitOwnedPaths(allocator, &reachable);

        for (reachable.items) |path| {
            if (docent.targeting.shouldSkipLintFile(path, plan.targeting)) continue;
            if (try analyzed_files.put(allocator, io, path)) continue;
            if (try analyzeFile(allocator, io, path, rule_set, complexity_options, all_diagnostics, summary, fail_fast)) return true;
        }
    }

    for (plan.extra_lint_files) |path| {
        if (try analyzed_files.put(allocator, io, path)) continue;
        if (try analyzeFile(allocator, io, path, rule_set, complexity_options, all_diagnostics, summary, fail_fast)) return true;
    }

    return false;
}

fn analyzeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rule_set: docent.RuleSeverities,
    complexity_options: docent.rules.complexity.Options,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    fail_fast: cli_types.FailFast,
) !bool {
    var result = docent.lintComplexityFile(allocator, io, path, rule_set, complexity_options) catch |err| {
        try check_shared.printStderr(io, "error: failed to analyze '{s}': {}\n", .{ path, err });
        return false;
    };
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        summary.observe(d);
        try all_diagnostics.append(allocator, try docent.Diagnostic.cloneAlloc(d, allocator));

        if (check_shared.failFastMatches(fail_fast, d.severity_level)) return true;
    }

    return false;
}
