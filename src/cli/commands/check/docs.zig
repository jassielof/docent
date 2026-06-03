//! `docent check docs` — documentation comment rules.

const std = @import("std");

const carnaval = @import("carnaval");
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

    try docs_cmd.addFlag(cli_types.OutputMode, .{
        .name = "format",
        .short = 'f',
        .brief = "Output format",
        .value_hint = "FORMAT",
        .default = .pretty,
        .allowed_values_style = .comma,
    });

    try docs_cmd.addFlag(cli_types.FailFast, .{
        .name = "fail-fast",
        .short = 'F',
        .brief = "Stop after the first matching severity",
        .value_hint = "WHEN",
        .default = cli_types.default_fail_fast,
    });

    docs_cmd.setHooks(.{ .run = &run });
}

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
    format: cli_types.OutputMode = .pretty,
    fail_fast: cli_types.FailFast = cli_types.default_fail_fast,
};

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const args = try ctx.extract(Args);
    const target = targetArgs(args);

    const rule_set = docent.config.loadRuleSetFromCli(allocator, io, target.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    const docs_options = docent.config.loadDocsOptionsFromCli(allocator, io, target.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    const docs_public_api_only = docent.config.loadDocsPublicApiOnlyFromCli(allocator, io, target.config_path) catch |err| {
        try check_shared.printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    var plan = check_shared.gatherPlan(allocator, io, target) catch |err| {
        try check_shared.printStderr(io, "error: failed to build lint plan: {}\n", .{err});
        std.process.exit(1);
    };
    defer plan.deinit(allocator);

    const path_display_root = try allocPathDisplayRoot(allocator, io);
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

    const text_options = docent.output.stderrTextOptions(io, textFormat(args.format), .auto, path_display_root);

    for (plan.resolved_targets) |rt| {
        if (rt.status == .linted) {
            for (rt.files) |path| {
                const gptr = try linted_files.getOrPut(path);
                if (gptr.found_existing) continue;

                if (try lintPlanFileWithFailFast(allocator, io, path, rule_set, lint_options, library_entry_roots_owned, docs_options, &all_diagnostics, &summary, args.fail_fast)) {
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

            if (try lintPlanFileWithFailFast(allocator, io, path, rule_set, lint_options, library_entry_roots_owned, docs_options, &all_diagnostics, &summary, args.fail_fast)) {
                should_stop = true;
                break;
            }
        }
    }

    if (args.format == .json) {
        try docent.output.printJsonStdout(io, allocator, all_diagnostics.items);
    } else {
        try docent.output.printDiagnosticsStderr(io, all_diagnostics.items, text_options);
        const had_diagnostics = summary.errors > 0 or summary.warnings > 0;
        try docent.output.printSummaryStderr(io, summary, docent.output.stderrSummaryOptions(io, "docent check docs", .auto), had_diagnostics);
    }

    if (summary.hasErrors()) std.process.exit(1);
}

fn failFastMatches(ff: cli_types.FailFast, severity_level: docent.SeverityLevel) bool {
    return switch (ff) {
        .none => false,
        .@"error" => severity_level.isError(),
        .warn => severity_level == .warn,
        .any => severity_level == .warn or severity_level.isError(),
    };
}

fn allocPathDisplayRoot(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const manifest = docent.manifest.findNearestManifestPath(allocator, io) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return realPathFileAlloc(allocator, io, "."),
    };
    defer allocator.free(manifest);
    const dir = std.fs.path.dirname(manifest) orelse return realPathFileAlloc(allocator, io, ".");
    return realPathFileAlloc(allocator, io, dir);
}

fn realPathFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
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
) !void {
    _ = try lintPlanFileWithFailFast(allocator, io, path, rule_set, lint_options, library_entry_roots, docs_options, all_diagnostics, summary, .none);
}

fn lintPlanFileWithFailFast(
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

        if (failFastMatches(fail_fast, d.severity_level)) return true;
    }

    return false;
}

fn textFormat(mode: cli_types.OutputMode) docent.output.TextFormat {
    return switch (mode) {
        .pretty => .pretty,
        .minimal => .minimal,
        .json => unreachable,
    };
}

fn targetArgs(args: Args) check_shared.TargetArgs {
    return .{
        .positionals = args.positionals,
        .config_path = args.config_path,
        .lib = args.lib,
        .bins = args.bins,
        .bin = args.bin,
        .tests = args.tests,
        .@"test" = args.@"test",
        .deps = args.deps,
        .build_script = args.build_script,
    };
}
