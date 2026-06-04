//! `docent check docs` — documentation comment rules.

const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");

const cli_types = @import("../../types.zig");
const check_shared = @import("../../check_shared.zig");

pub fn register(check: *fangz.Command) !void {
    const docs_cmd = try check.addSubcommand(.{
        .name = "docs",
        .brief = "Check documentation comments",
        .description = "Lint doc comments on the public API surface (or all declarations when scan_mode is \"all\" in config). Exits non-zero when a denied rule reports a finding.",
    });

    try check_shared.registerTargetFlags(docs_cmd);
    try check_shared.registerOutputFlags(docs_cmd);
    docs_cmd.setHooks(.{ .run = &run });
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

    const docs_public_api_only = docent.config.loadDocsPublicApiOnlyFromCli(allocator, io, args.config_path) catch |err| {
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

    var linted_files = std.StringHashMap(void).init(allocator);
    defer linted_files.deinit();

    var should_stop = false;

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

    const lint_options: docent.LintOptions = switch (plan.path_mode) {
        .project, .module_root => .{
            .module_name = plan.package.name,
            .public_api_only = docs_public_api_only,
        },
        .recursive => .{
            .public_api_only = false,
        },
    };

    for (plan.resolved_targets) |rt| {
        if (rt.status == .linted) {
            for (rt.files) |path| {
                const gptr = try linted_files.getOrPut(path);
                if (gptr.found_existing) continue;

                if (try lintPlanFile(allocator, io, path, rule_set, lint_options, library_entry_roots_owned, docs_options, &all_diagnostics, &summary, args.fail_fast)) {
                    should_stop = true;
                    break;
                }
            }
        }
        if (should_stop) break;
    }

    if (!should_stop) {
        for (plan.extra_lint_files) |path| {
            const gptr = try linted_files.getOrPut(path);
            if (gptr.found_existing) continue;

            if (try lintPlanFile(allocator, io, path, rule_set, lint_options, library_entry_roots_owned, docs_options, &all_diagnostics, &summary, args.fail_fast)) {
                break;
            }
        }
    }

    try check_shared.printCheckResults(io, allocator, args, "docent check docs", all_diagnostics.items, summary, path_display_root);

    if (summary.hasErrors()) std.process.exit(1);
}

pub fn lintPlanFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rule_set: docent.RuleSet,
    lint_options: docent.LintOptions,
    library_entry_roots: []const []const u8,
    docs_options: docent.DocsOptions,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    fail_fast: cli_types.FailFast,
) !bool {
    var result = docent.lintFile(allocator, io, path, rule_set, lint_options, library_entry_roots, docs_options) catch |err| {
        try check_shared.printStderr(io, "error: failed to lint '{s}': {}\n", .{ path, err });
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
