//! Build-system integration: custom `build.zig` step that runs Docent during `zig build`.

const std = @import("std");
const docent = @import("root.zig");

/// Custom build step that lints Zig sources and fails the build on configured severities.
pub const LintStep = struct {
    /// Underlying Zig build step (`docent`).
    step: std.Build.Step,
    /// Explicit sources; empty means load `.paths` from the nearest manifest at run time.
    sources: []const []const u8,
    /// When set, overrides `.config/docent.json` and defaults.
    rules_override: ?docent.RuleSet,
    /// Target filters (library vs binaries vs tests, dependency roots, etc.).
    targeting: docent.targeting.Options,
    /// Diagnostic output formatting for stderr.
    output: OutputOptions,

    /// Creates and returns a `LintStep` owned by `b`.
    pub fn create(b: *std.Build, options: Options) *LintStep {
        const self = b.allocator.create(LintStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "docent",
                .owner = b,
                .makeFn = make,
            }),
            .sources = if (options.sources) |sources|
                b.allocator.dupe([]const u8, sources) catch @panic("OOM")
            else
                &.{},
            .rules_override = options.rules,
            .targeting = options.targeting orelse .{
                .lib = options.lib,
                .bins = options.bins,
                .bin_names = options.bin_names orelse &.{},
                .tests = options.tests,
                .test_names = options.test_names orelse &.{},
                .deps = options.deps,
                .build_script = options.build_script,
                .exclude_roots = options.exclude_roots orelse &.{},
            },
            .output = options.output,
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *LintStep = @fieldParentPtr("step", step);
        const allocator = step.owner.allocator;
        const io = step.owner.graph.io;

        const rule_set: docent.RuleSet = if (self.rules_override) |rules|
            rules
        else
            try docent.config.loadNearestRuleSet(allocator, io);

        const docs_options = docent.config.loadDocsOptionsFromCli(allocator, io, null) catch return error.MakeFailed;

        var manifest_sources: std.ArrayList([]const u8) = .empty;
        defer if (manifest_sources.items.len > 0) docent.manifest.deinitOwnedPaths(allocator, &manifest_sources);

        const sources: []const []const u8 = if (self.sources.len > 0)
            self.sources
        else blk: {
            manifest_sources = docent.manifest.loadNearestPackagePaths(allocator, io) catch |err| switch (err) {
                error.ManifestNotFound, error.ManifestPathsNotFound => fallback: {
                    var fallback: std.ArrayList([]const u8) = .empty;
                    const cwd = realPathFileAlloc(allocator, io, ".") catch return error.MakeFailed;
                    try fallback.append(allocator, cwd);
                    break :fallback fallback;
                },
                else => return err,
            };
            break :blk manifest_sources.items;
        };

        var targeting = self.targeting;
        if (targeting.exclude_roots.len == 0 and !targeting.deps) {
            var exclude_roots = docent.manifest.loadNearestDependencyPathRoots(allocator, io) catch std.ArrayList([]const u8).empty;
            defer docent.manifest.deinitOwnedPaths(allocator, &exclude_roots);
            if (exclude_roots.items.len > 0) {
                targeting.exclude_roots = try allocator.dupe([]const u8, exclude_roots.items);
            }
        }

        const path_display_root: ?[]const u8 = realPathFileAlloc(allocator, io, ".") catch null;
        defer if (path_display_root) |p| allocator.free(p);

        const project_root = path_display_root orelse ".";
        const library_entry_roots = docent.collectLibraryEntryRoots(allocator, io, project_root) catch &.{};
        defer {
            for (library_entry_roots) |root| allocator.free(root);
            allocator.free(library_entry_roots);
        }

        var summary: docent.output.Summary = .{};
        var total_files: usize = 0;

        for (sources) |source_path| {
            const stat = std.Io.Dir.cwd().statFile(io, source_path, .{}) catch |err| {
                if (err == error.IsDir) {
                    try lintDirectory(rule_set, docs_options, targeting, self.output, allocator, io, source_path, step, &summary, &total_files, path_display_root, library_entry_roots);
                    continue;
                }
                step.result_error_msgs.append(
                    allocator,
                    std.fmt.allocPrint(allocator, "cannot access '{s}': {}", .{ source_path, err }) catch @panic("OOM"),
                ) catch @panic("OOM");
                return error.MakeFailed;
            };

            if (stat.kind == .directory) {
                try lintDirectory(rule_set, docs_options, targeting, self.output, allocator, io, source_path, step, &summary, &total_files, path_display_root, library_entry_roots);
            } else {
                if (docent.targeting.shouldSkipLintFile(source_path, targeting)) continue;
                try lintSingleFile(rule_set, docs_options, self.output, allocator, io, source_path, step, &summary, &total_files, path_display_root, library_entry_roots);
            }
        }

        if (summary.errors > 0) {
            step.result_error_msgs.append(
                allocator,
                std.fmt.allocPrint(allocator, "doc_lint: {d} error(s), {d} warning(s) in {d} file(s)", .{ summary.errors, summary.warnings, total_files }) catch @panic("OOM"),
            ) catch @panic("OOM");
            return error.MakeFailed;
        }
    }
};

fn lintDirectory(
    rule_set: docent.RuleSet,
    docs_options: docent.DocsOptions,
    targeting: docent.targeting.Options,
    output: OutputOptions,
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    step: *std.Build.Step,
    summary: *docent.output.Summary,
    total_files: *usize,
    path_display_root: ?[]const u8,
    library_entry_roots: []const []const u8,
) !void {
    var targets = docent.targeting.collectDirectoryLintTargets(
        allocator,
        io,
        dir_path,
        targeting,
    ) catch |err| {
        step.result_error_msgs.append(
            allocator,
            std.fmt.allocPrint(allocator, "cannot collect lint targets in '{s}': {}", .{ dir_path, err }) catch @panic("OOM"),
        ) catch @panic("OOM");
        return error.MakeFailed;
    };
    defer docent.targeting.deinitOwnedPaths(allocator, &targets);

    for (targets.items) |full_path| {
        try lintSingleFile(rule_set, docs_options, output, allocator, io, full_path, step, summary, total_files, path_display_root, library_entry_roots);
    }
}

fn lintSingleFile(
    rule_set: docent.RuleSet,
    docs_options: docent.DocsOptions,
    output: OutputOptions,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    step: *std.Build.Step,
    summary: *docent.output.Summary,
    total_files: *usize,
    path_display_root: ?[]const u8,
    library_entry_roots: []const []const u8,
) !void {
    var result = docent.lintFile(allocator, io, path, rule_set, .{}, library_entry_roots, docs_options) catch |err| {
        step.result_error_msgs.append(
            allocator,
            std.fmt.allocPrint(allocator, "failed to lint '{s}': {}", .{ path, err }) catch @panic("OOM"),
        ) catch @panic("OOM");

        return error.MakeFailed;
    };
    defer result.deinit();

    var file_has_errors = false;
    for (result.diagnostics.items) |d| {
        summary.observe(d);
        switch (d.severity_level) {
            .allow => continue,
            .warn => {
                try docent.output.printDiagnosticStderr(io, d, docent.output.stderrTextOptions(io, output.format, output.color, path_display_root));
            },
            .deny, .forbid => {
                file_has_errors = true;
                try docent.output.printDiagnosticStderr(io, d, docent.output.stderrTextOptions(io, output.format, output.color, path_display_root));
            },
        }
    }
    if (file_has_errors) total_files.* += 1;
}

/// Options for `addLintStep` / `LintStep.create`.
pub const Options = struct {
    /// Lint roots; when null, uses `.paths` from the nearest `build.zig.zon`.
    sources: ?[]const []const u8 = null,
    /// When null, uses `.config/docent.json` or `RuleSet` defaults.
    rules: ?docent.RuleSet = null,
    /// Full targeting options; when null, the other options are used.
    targeting: ?docent.targeting.Options = null,
    /// Lint library targets only (used when `targeting` is null).
    lib: bool = false,
    /// Lint all binary targets (used when `targeting` is null).
    bins: bool = false,
    /// Lint specific binaries by name (used when `targeting` is null).
    bin_names: ?[]const []const u8 = null,
    /// Lint all test targets (used when `targeting` is null).
    tests: bool = false,
    /// Lint specific tests by name (used when `targeting` is null).
    test_names: ?[]const []const u8 = null,
    /// Also lint files under path dependencies from `build.zig.zon`.
    deps: bool = false,
    /// Include `build.zig` and `build/*.zig` in lint targets.
    build_script: bool = false,
    /// Directory roots excluded from lint (e.g. path dependencies).
    exclude_roots: ?[]const []const u8 = null,
    /// Diagnostic output options for the build step.
    output: OutputOptions = .{},
};

/// Output formatting options for diagnostics printed during the build step.
pub const OutputOptions = struct {
    /// Text layout for each diagnostic line.
    format: docent.output.TextFormat = .pretty,
    /// When ANSI colors are applied to build-step output.
    color: docent.output.ColorMode = .auto,
};

/// Registers a Docent lint step on `b` and returns it for `dependOn` / `enableIf`.
pub fn addLintStep(b: *std.Build, options: Options) *LintStep {
    return LintStep.create(b, options);
}

fn realPathFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}
