//! `docent check all` — run docs, style, complexity, and size checks with full diagnostics.

const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");

const complexity_check = @import("complexity.zig");
const size_check = @import("size.zig");
const doc_check = @import("doc.zig");
const check_shared = docent.check_shared;
const style_check = @import("style.zig");

pub fn register(check: *fangz.Command) !void {
    const all_cmd = try check.addSubcommand(.{
        .name = "all",
        .brief = "Run every check category",
        .description = "Run documentation, style, complexity, and size checks in one pass and print all diagnostics. Exits non-zero when a denied rule reports a finding.",
    });

    try check_shared.registerCategoryPositionals(all_cmd);
    try check_shared.registerOutputFlags(all_cmd);
    all_cmd.setHooks(.{ .run = &run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const args = try ctx.extract(check_shared.TargetArgs);

    const doc_options = docent.config.loadDocOptionsFromCli(allocator, io, args.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    const complexity_options = docent.config.loadComplexityOptionsFromCli(allocator, io, args.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    const size_options = docent.config.loadSizeOptionsFromCli(allocator, io, args.config_path) catch |err| {
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

    const path_display_root = try check_shared.allocPathDisplayRoot(allocator, io);
    defer allocator.free(path_display_root);

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

    var doc_opts = doc_options;
    var style_opts = style_options;
    var complexity_opts = complexity_options;
    var size_opts = size_options;
    if (plan.path_mode == .recursive) {
        doc_opts.applyRunScanMode(.reachability_traversal);
        style_opts.applyRunScanMode(.reachability_traversal);
        complexity_opts.applyRunScanMode(.reachability_traversal);
        size_opts.applyRunScanMode(.reachability_traversal);
    }

    const doc_lint_options: docent.LintOptions = switch (plan.path_mode) {
        .project, .module_root => .{ .module_name = plan.package.name },
        .recursive => .{},
    };

    var linted_files = std.StringHashMap(void).init(allocator);
    defer linted_files.deinit();

    var should_stop = false;

    for (plan.resolved_targets) |rt| {
        if (should_stop) break;
        if (rt.status != .linted) continue;
        for (rt.files) |path| {
            const gptr = try linted_files.getOrPut(path);
            if (gptr.found_existing) continue;
            if (try doc_check.lintPlanFile(allocator, io, path, doc_lint_options, library_entry_roots_owned, doc_opts, &all_diagnostics, &summary, args.fail_fast)) {
                should_stop = true;
                break;
            }
        }
    }

    if (!should_stop) {
        for (plan.extra_lint_files) |path| {
            const gptr = try linted_files.getOrPut(path);
            if (gptr.found_existing) continue;
            if (try doc_check.lintPlanFile(allocator, io, path, doc_lint_options, library_entry_roots_owned, doc_opts, &all_diagnostics, &summary, args.fail_fast)) {
                should_stop = true;
                break;
            }
        }
    }

    if (!should_stop) {
        var analyzed_files = docent.scan.target.PathSet.init(allocator);
        defer analyzed_files.deinit(allocator);

        if (try style_check.analyzeReachableTargets(allocator, io, &plan, &analyzed_files, style_opts, &all_diagnostics, &summary, args.fail_fast)) {
            should_stop = true;
        } else {
            analyzed_files.clear(allocator);
            if (try complexity_check.analyzeReachableTargets(allocator, io, &plan, &analyzed_files, complexity_opts, &all_diagnostics, &summary, args.fail_fast)) {
                should_stop = true;
            } else {
                analyzed_files.clear(allocator);
                if (try size_check.analyzeReachableTargets(allocator, io, &plan, &analyzed_files, size_opts, &all_diagnostics, &summary, args.fail_fast)) {
                    should_stop = true;
                }
            }
        }
    }

    try check_shared.printCheckResults(io, allocator, args, "docent check all", all_diagnostics.items, summary, path_display_root);

    if (summary.hasErrors()) std.process.exit(1);
}
