//! `docent check` — run lint rules by category or print a combined summary.

const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");

const all_check = @import("check/all.zig");
const complexity_check = @import("check/complexity.zig");
const docs_check = @import("check/docs.zig");
const check_shared = @import("../check_shared.zig");
const style_check = @import("check/style.zig");

/// Registers the `check` command and its category subcommands on `root`.
pub fn register(root: *fangz.Command) !void {
    const check_cmd = try root.addSubcommand(.{
        .name = "check",
        .brief = "Run Docent lint checks",
        .description = "Run documentation, style, or complexity checks. Use a category subcommand for full diagnostics, or run `docent check` alone for a compact summary across every category.",
    });

    try check_shared.registerTargetFlags(check_cmd, .{ .persistent = true, .positionals = false });
    check_cmd.setHooks(.{ .run = &runSummary });

    try docs_check.register(check_cmd);
    try style_check.register(check_cmd);
    try complexity_check.register(check_cmd);
    try all_check.register(check_cmd);
}

fn runSummary(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const args = try ctx.extract(check_shared.TargetArgs);

    const rule_set = docent.config.loadRuleSeveritiesFromCli(allocator, io, args.config_path) catch |err| {
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

    const style_options = docent.config.loadStyleOptionsFromCli(allocator, io, args.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    var plan = check_shared.gatherPlan(allocator, io, args) catch |err| {
        try check_shared.printStderr(io, "error: failed to build lint plan: {}\n", .{err});
        std.process.exit(1);
    };
    defer plan.deinit(allocator);

    var all_diagnostics: std.ArrayList(docent.Diagnostic) = .empty;
    defer {
        for (all_diagnostics.items) |d| docent.Diagnostic.deinitAlloc(d, allocator);
        all_diagnostics.deinit(allocator);
    }

    var summary: docent.output.Summary = .{};

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

    var docs_opts = docs_options;
    var style_opts = style_options;
    var complexity_opts = complexity_options;
    if (plan.path_mode == .recursive) {
        docs_opts.applyRunScanMode(.reachability_traversal);
        style_opts.applyRunScanMode(.reachability_traversal);
        complexity_opts.applyRunScanMode(.reachability_traversal);
    }

    const docs_lint_options: docent.LintOptions = switch (plan.path_mode) {
        .project, .module_root => .{ .module_name = plan.package.name },
        .recursive => .{},
    };

    var linted_files = std.StringHashMap(void).init(allocator);
    defer linted_files.deinit();

    for (plan.resolved_targets) |rt| {
        if (rt.status != .linted) continue;
        for (rt.files) |path| {
            const gptr = try linted_files.getOrPut(path);
            if (gptr.found_existing) continue;
            _ = try docs_check.lintPlanFile(allocator, io, path, rule_set, docs_lint_options, library_entry_roots_owned, docs_opts, &all_diagnostics, &summary, .none);
        }
    }

    for (plan.extra_lint_files) |path| {
        const gptr = try linted_files.getOrPut(path);
        if (gptr.found_existing) continue;
        _ = try docs_check.lintPlanFile(allocator, io, path, rule_set, docs_lint_options, library_entry_roots_owned, docs_opts, &all_diagnostics, &summary, .none);
    }

    var analyzed_files = docent.targeting.PathSet.init(allocator);
    defer analyzed_files.deinit(allocator);

    _ = try style_check.analyzeReachableTargets(allocator, io, &plan, &analyzed_files, rule_set, style_opts, &all_diagnostics, &summary, .none);
    analyzed_files.clear(allocator);
    _ = try complexity_check.analyzeReachableTargets(allocator, io, &plan, &analyzed_files, rule_set, complexity_opts, &all_diagnostics, &summary, .none);

    var count_rows: std.ArrayList(check_shared.RuleCountRow) = .empty;
    defer count_rows.deinit(allocator);

    try check_shared.appendDiagnosticCounts(allocator, all_diagnostics.items, &count_rows);
    try check_shared.printCategorizedSummary(allocator, io, count_rows.items);

    if (summary.errors > 0 or summary.warnings > 0) {
        std.process.exit(1);
    }
}
