//! `docent check complexity` — cognitive and cyclomatic complexity rules.

const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");

const cli_types = @import("../../types.zig");
const check_shared = @import("../../check_shared.zig");

pub fn register(check: *fangz.Command) !void {
    const complexity_cmd = try check.addSubcommand(.{
        .name = "complexity",
        .brief = "Check function complexity",
        .description = "Measure cognitive and cyclomatic complexity for every function reachable from the project's module roots. Thresholds are set in project config (.config/docent.toml). Exits non-zero when a denied rule reports a finding.",
    });

    try check_shared.registerCategoryPositionals(complexity_cmd);
    try check_shared.registerOutputFlags(complexity_cmd);
    complexity_cmd.setHooks(.{ .run = &run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const args = try ctx.extract(check_shared.TargetArgs);

    const complexity_cfg = docent.config.loadComplexityOptionsFromCli(allocator, io, args.config_path) catch |err| {
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

    var analyzed_files = docent.scan.target.PathSet.init(allocator);
    defer analyzed_files.deinit(allocator);

    _ = try analyzeReachableTargets(allocator, io, &plan, &analyzed_files, complexity_cfg, &all_diagnostics, &summary, args.fail_fast);

    try check_shared.printCheckResults(io, allocator, args, "docent check complexity", all_diagnostics.items, summary, path_display_root);

    if (summary.hasErrors()) std.process.exit(1);
}

pub fn analyzeReachableTargets(
    allocator: std.mem.Allocator,
    io: std.Io,
    plan: *const docent.status_plan.Plan,
    analyzed_files: *docent.scan.target.PathSet,
    complexity_cfg: docent.rules.complexity.Complexity,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    fail_fast: cli_types.FailFast,
) !bool {
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    for (plan.resolved_targets) |rt| {
        if (rt.status != .linted) continue;

        const abs_root = if (std.fs.path.isAbsolute(rt.root_source_file))
            try allocator.dupe(u8, rt.root_source_file)
        else
            try std.fs.path.join(allocator, &.{ plan.package.project_root, rt.root_source_file });
        defer allocator.free(abs_root);

        var reachable = docent.scan.reach.collectReachableFiles(allocator, io, abs_root) catch |err| {
            try check_shared.printStderr(io, "error: failed to resolve reachable files for '{s}': {}\n", .{ rt.root_source_file, err });
            continue;
        };
        defer docent.scan.reach.deinitOwnedPaths(allocator, &reachable);

        for (reachable.items) |path| {
            if (docent.scan.target.shouldSkipLintFile(path, plan.targeting)) continue;
            if (try analyzed_files.put(allocator, io, path)) continue;
            try paths.append(allocator, try allocator.dupe(u8, path));
        }
    }

    for (plan.extra_lint_files) |path| {
        if (try analyzed_files.put(allocator, io, path)) continue;
        try paths.append(allocator, try allocator.dupe(u8, path));
    }

    if (paths.items.len == 0) return false;

    // Parallel per-file analysis via Io.Group (same pattern as scan/reach.zig).
    // Diagnostics are merged under a mutex; fail-fast is checked after the group awaits.
    var state = ParallelLintState{
        .allocator = allocator,
        .io = io,
        .complexity_cfg = complexity_cfg,
        .all_diagnostics = all_diagnostics,
        .summary = summary,
        .fail_fast = fail_fast,
    };

    for (paths.items) |path| {
        state.group.async(io, ParallelLintState.analyzeTask, .{ &state, path });
    }
    try state.group.await(io);

    return state.hit_fail_fast;
}

const ParallelLintState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    complexity_cfg: docent.rules.complexity.Complexity,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    fail_fast: cli_types.FailFast,
    mutex: std.Io.Mutex = .init,
    group: std.Io.Group = .init,
    hit_fail_fast: bool = false,

    fn analyzeTask(self: *ParallelLintState, path: []const u8) std.Io.Cancelable!void {
        var result = docent.lintComplexityFile(self.allocator, self.io, path, self.complexity_cfg) catch |err| {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            check_shared.printStderr(self.io, "error: failed to analyze '{s}': {}\n", .{ path, err }) catch {};
            return;
        };
        defer result.deinit();

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        for (result.diagnostics.items) |d| {
            self.summary.observe(d);
            const cloned = docent.Diagnostic.cloneAlloc(d, self.allocator) catch return;
            self.all_diagnostics.append(self.allocator, cloned) catch return;
            if (check_shared.failFastMatches(self.fail_fast, d.severity_level)) {
                self.hit_fail_fast = true;
            }
        }
    }
};
