//! `docent check all` — run docs, style, and complexity checks with full diagnostics.

const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");

const complexity_check = @import("complexity.zig");
const docs_check = @import("docs.zig");
const check_shared = @import("../../check_shared.zig");
const style_check = @import("style.zig");

pub fn register(check: *fangz.Command) !void {
    const all_cmd = try check.addSubcommand(.{
        .name = "all",
        .brief = "Run every check category",
        .description = "Run documentation, style, and complexity checks in one pass and print all diagnostics. Exits non-zero when a denied rule reports a finding.",
    });

    try check_shared.registerTargetFlags(all_cmd);
    all_cmd.setHooks(.{ .run = &run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const args = try ctx.extract(check_shared.TargetArgs);

    const rule_set = docent.config.loadRuleSetFromCli(allocator, io, args.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    const docs_options = docent.config.loadDocsOptionsFromCli(allocator, io, args.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    const complexity_options = docent.config.loadComplexityOptionsFromCli(allocator, io, args.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    const docs_public_api_only = docent.config.loadDocsPublicApiOnlyFromCli(allocator, io, args.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    const style_public_api_only = docent.config.loadStylePublicApiOnlyFromCli(allocator, io, args.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    const complexity_public_api_only = docent.config.loadComplexityPublicApiOnlyFromCli(allocator, io, args.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    var plan = check_shared.gatherPlan(allocator, io, args) catch |err| {
        try check_shared.printStderr(io, "error: failed to build lint plan: {}\n", .{err});
        std.process.exit(1);
    };
    defer plan.deinit(allocator);

    var summary: docent.output.Summary = .{};
    var all_diagnostics: std.ArrayList(docent.Diagnostic) = .empty;
    defer {
        for (all_diagnostics.items) |d| docent.Diagnostic.deinitAlloc(d, allocator);
        all_diagnostics.deinit(allocator);
    }

    const library_entry_roots_owned = blk: {
        if (plan.path_mode == .recursive) break :blk &.{};
        if (plan.path_mode == .module_root) break :blk plan.module_entry_roots;
        const roots = docent.collectLibraryEntryRoots(allocator, io, plan.package.project_root) catch &.{};
        break :blk roots;
    };
    defer if (plan.path_mode == .project) {
        for (library_entry_roots_owned) |root_path| allocator.free(root_path);
        allocator.free(library_entry_roots_owned);
    };

    const docs_lint_options: docent.LintOptions = switch (plan.path_mode) {
        .project, .module_root => .{
            .module_name = plan.package.name,
            .public_api_only = docs_public_api_only,
        },
        .recursive => .{
            .public_api_only = false,
        },
    };

    const reachability_lint_options: docent.LintOptions = .{
        .module_name = plan.package.name,
        .public_api_only = style_public_api_only,
    };

    const complexity_lint_options: docent.LintOptions = .{
        .module_name = plan.package.name,
        .public_api_only = complexity_public_api_only,
    };

    var linted_files = std.StringHashMap(void).init(allocator);
    defer linted_files.deinit();

    for (plan.resolved_targets) |rt| {
        if (rt.status != .linted) continue;
        for (rt.files) |path| {
            const gptr = try linted_files.getOrPut(path);
            if (gptr.found_existing) continue;
            try docs_check.lintPlanFile(allocator, io, path, rule_set, docs_lint_options, library_entry_roots_owned, docs_options, &all_diagnostics, &summary);
        }
    }

    for (plan.extra_lint_files) |path| {
        const gptr = try linted_files.getOrPut(path);
        if (gptr.found_existing) continue;
        try docs_check.lintPlanFile(allocator, io, path, rule_set, docs_lint_options, library_entry_roots_owned, docs_options, &all_diagnostics, &summary);
    }

    var analyzed_files = std.StringHashMap(void).init(allocator);
    defer analyzed_files.deinit();

    try style_check.analyzeReachableTargets(allocator, io, &plan, &analyzed_files, rule_set, reachability_lint_options, &all_diagnostics, &summary);

    analyzed_files.clearRetainingCapacity();
    try complexity_check.analyzeReachableTargets(allocator, io, &plan, &analyzed_files, rule_set, complexity_lint_options, complexity_options, &all_diagnostics, &summary);

    const text_options = docent.output.stderrTextOptions(io, .pretty, .auto, plan.package.project_root);
    try docent.output.printDiagnosticsStderr(io, all_diagnostics.items, text_options);
    const had_diagnostics = summary.errors > 0 or summary.warnings > 0;
    try docent.output.printSummaryStderr(io, summary, docent.output.stderrSummaryOptions(io, "docent check all", .auto), had_diagnostics);

    if (summary.hasErrors()) std.process.exit(1);
}
