//! `docent check style` — naming-case and related style rules.

const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");

const cli_types = docent.types;
const check_shared = docent.check_shared;

pub fn register(check: *fangz.Command) !void {
    const style_cmd = try check.addSubcommand(.{
        .name = "style",
        .brief = "Check naming-case and style rules",
        .description = "Check identifiers in the import-closure reachable from the project's module roots. Severities are set in project config (.config/docent.toml). Exits non-zero when a denied rule reports a finding.",
    });

    try check_shared.registerCategoryPositionals(style_cmd);
    try check_shared.registerOutputFlags(style_cmd);
    style_cmd.setHooks(.{ .run = &run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const args = try ctx.extract(check_shared.TargetArgs);

    const style_cfg = docent.config.loadStyleOptionsFromCli(
        allocator,
        io,
        args.config_path,
    ) catch |err| {
        try check_shared.printStderr(
            io,
            "error: {s}\n",
            .{docent.config.formatError(err)},
        );
        std.process.exit(1);
    };

    var plan = check_shared.gatherPlan(
        allocator,
        io,
        args,
    ) catch |err| {
        try check_shared.printStderr(
            io,
            "error: failed to build lint plan: {}\n",
            .{err},
        );
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

    var analyzed_files = docent.scan.target.PathSet.init(allocator);
    defer analyzed_files.deinit(allocator);

    _ = try analyzeReachableTargets(
        allocator,
        io,
        &plan,
        &analyzed_files,
        style_cfg,
        &all_diagnostics,
        &summary,
        args.fail_fast,
    );

    try check_shared.printCheckResults(
        io,
        allocator,
        args,
        "docent check style",
        all_diagnostics.items,
        summary,
        path_display_root,
    );

    if (summary.hasErrors()) std.process.exit(1);
}

pub fn analyzeReachableTargets(
    allocator: std.mem.Allocator,
    io: std.Io,
    plan: *const docent.status_plan.Plan,
    analyzed_files: *docent.scan.target.PathSet,
    style_cfg: docent.rules.style.Style,
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

        var reachable = docent.scan.reach.collectReachableFiles(
            allocator,
            io,
            abs_root,
        ) catch |err| {
            try check_shared.printStderr(
                io,
                "error: failed to resolve reachable files for '{s}': {}\n",
                .{ rt.root_source_file, err },
            );
            continue;
        };
        defer docent.scan.reach.deinitOwnedPaths(allocator, &reachable);

        for (reachable.items) |path| {
            if (docent.scan.target.shouldSkipLintFile(path, plan.targeting)) continue;
            if (try analyzed_files.put(
                allocator,
                io,
                path,
            )) continue;
            if (try analyzeFile(
                allocator,
                io,
                path,
                style_cfg,
                all_diagnostics,
                summary,
                fail_fast,
            )) return true;
        }
    }

    for (plan.extra_lint_files) |path| {
        if (try analyzed_files.put(
            allocator,
            io,
            path,
        )) continue;
        if (try analyzeFile(
            allocator,
            io,
            path,
            style_cfg,
            all_diagnostics,
            summary,
            fail_fast,
        )) return true;
    }

    return false;
}

fn analyzeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    style_cfg: docent.rules.style.Style,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    fail_fast: cli_types.FailFast,
) !bool {
    var result = docent.lintStyleFile(
        allocator,
        io,
        path,
        style_cfg,
    ) catch |err| {
        try check_shared.printStderr(
            io,
            "error: failed to analyze '{s}': {}\n",
            .{ path, err },
        );
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
