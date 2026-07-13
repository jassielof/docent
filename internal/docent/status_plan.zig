//! Builds the lint plan used by `docent status` and the default CLI run (targets, paths, skip reasons).

const std = @import("std");
const carnaval = @import("carnaval");

const manifest = @import("manifest.zig");
const targeting = @import("scan/target.zig");
const build_scan = @import("build_scan.zig");
const reach = @import("scan/reach.zig");

/// One build target after applying lint filters, with the files that would be checked.
pub const ResolvedTarget = struct {
    /// Step name from `build.zig` (for example `docent` or an executable name).
    name: []const u8,
    /// Whether this row is a library, executable, or test target.
    kind: build_scan.TargetKind,
    /// `root_source_file` path from the build script, as written in `build.zig`.
    root_source_file: []const u8,
    /// Whether files for this target are included in the lint run.
    status: enum { linted, skipped },
    /// Human-readable explanation for `status` (included or skipped reason).
    reason: []const u8,
    /// Absolute paths of Zig files that would be linted when `status == .linted`.
    files: []const []const u8,

    /// Frees all owned strings and the `files` slice.
    pub fn deinit(self: *ResolvedTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.root_source_file);
        allocator.free(self.reason);
        for (self.files) |f| allocator.free(f);
        allocator.free(self.files);
    }
};

/// How explicit CLI paths select files to lint.
pub const PathMode = enum {
    /// No paths: discover library targets from `build.zig` and lint the public API surface.
    project,
    /// One path: treat a single `.zig` file or package directory as a module root (public API surface).
    module_root,
    /// Two or more paths: recursively lint every `.zig` file under the paths (all declarations).
    recursive,
};

/// Inputs for `gather` (CLI flags and optional manifest override).
pub const Options = struct {
    /// When true, include library targets from `build.zig`.
    lib: bool = false,
    /// When true, include all executable targets.
    bins: bool = false,
    /// When non-empty, include only executables with matching step names.
    bin_names: []const []const u8 = &.{},
    /// When true, include all test targets.
    tests: bool = false,
    /// When non-empty, include only tests with matching step names.
    test_names: []const []const u8 = &.{},

    /// When true, also lint path-dependency trees from `build.zig.zon` (`.path` entries only).
    deps: bool = false,
    /// When true, include `build.zig` and `build/*.zig` in the plan.
    build_script: bool = false,

    /// Build-step names to skip (exact match). From `[check].exclude_targets` /
    /// `[typeset].exclude_targets` — filters the module graph, not filesystem paths.
    exclude_targets: []const []const u8 = &.{},

    /// Explicit file or directory paths from the command line (empty uses project discovery).
    positionals: []const []const u8 = &.{},
    /// When set, use this manifest instead of searching upward from cwd.
    manifest_path: ?[]const u8 = null,
    /// Terminal color profile for styled skip reasons in status output.
    color_profile: carnaval.ColorProfile = .none,
};

/// Result of planning a lint run: package metadata, per-target resolution, and extra paths.
pub const Plan = struct {
    /// Package name, version, and roots from `build.zig.zon` when available.
    package: manifest.PackageMeta,
    /// Build targets from `build.zig` with lint/skip status and file lists.
    resolved_targets: []ResolvedTarget,
    /// Additional files to lint from explicit paths or manifest `.paths` fallback.
    extra_lint_files: []const []const u8,
    /// How positional paths were interpreted.
    path_mode: PathMode,
    /// Module entry roots for `module_root` mode (`//!` and public reachability); empty otherwise.
    module_entry_roots: []const []const u8,
    /// Resolved targeting options used while building this plan.
    targeting: targeting.Options,

    /// Frees all owned data in the plan.
    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        for (self.resolved_targets) |*rt| rt.deinit(allocator);
        allocator.free(self.resolved_targets);
        for (self.extra_lint_files) |f| allocator.free(f);
        allocator.free(self.extra_lint_files);
        for (self.module_entry_roots) |r| allocator.free(r);
        allocator.free(self.module_entry_roots);

        for (self.targeting.bin_names) |name| allocator.free(name);
        allocator.free(self.targeting.bin_names);
        for (self.targeting.test_names) |name| allocator.free(name);
        allocator.free(self.targeting.test_names);
        for (self.targeting.exclude_roots) |root| allocator.free(root);
        allocator.free(self.targeting.exclude_roots);

        self.* = .{
            .package = .{ .project_root = "" },
            .resolved_targets = &.{},
            .extra_lint_files = &.{},
            .path_mode = .project,
            .module_entry_roots = &.{},
            .targeting = .{},
        };
    }
};

fn realPathFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

fn isReadableLocalFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn collectBuildFiles(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8, out: *std.ArrayList([]const u8)) !void {
    try targeting.collectBuildScriptLintFiles(allocator, io, project_root, out);
}

/// Resolves which files Docent would lint for the given options and project layout.
pub fn gather(allocator: std.mem.Allocator, io: std.Io, options: Options) !Plan {
    var package: manifest.PackageMeta = undefined;
    if (options.manifest_path) |mp| {
        package = try manifest.loadPackageMeta(allocator, io, mp);
    } else {
        package = try manifest.loadNearestPackageMeta(allocator, io);
    }
    errdefer package.deinit(allocator);

    var exclude_roots: std.ArrayList([]const u8) = .empty;
    defer manifest.deinitOwnedPaths(allocator, &exclude_roots);

    if (package.manifest_path) |manifest_path| {
        exclude_roots = manifest.loadDependencyPathRoots(allocator, io, manifest_path) catch .empty;
    }

    var duped_bin_names = try allocator.alloc([]const u8, options.bin_names.len);
    errdefer {
        for (duped_bin_names) |name| allocator.free(name);
        allocator.free(duped_bin_names);
    }
    for (options.bin_names, 0..) |name, idx| {
        duped_bin_names[idx] = try allocator.dupe(u8, name);
    }

    var duped_test_names = try allocator.alloc([]const u8, options.test_names.len);
    errdefer {
        for (duped_bin_names) |name| allocator.free(name);
        allocator.free(duped_bin_names);
        for (duped_test_names) |name| allocator.free(name);
        allocator.free(duped_test_names);
    }
    for (options.test_names, 0..) |name, idx| {
        duped_test_names[idx] = try allocator.dupe(u8, name);
    }

    var duped_exclude_roots = try allocator.alloc([]const u8, exclude_roots.items.len);
    errdefer {
        for (duped_bin_names) |name| allocator.free(name);
        allocator.free(duped_bin_names);
        for (duped_test_names) |name| allocator.free(name);
        allocator.free(duped_test_names);
        for (duped_exclude_roots) |root| allocator.free(root);
        allocator.free(duped_exclude_roots);
    }
    for (exclude_roots.items, 0..) |root, idx| {
        duped_exclude_roots[idx] = try allocator.dupe(u8, root);
    }

    const targeting_options: targeting.Options = .{
        .lib = options.lib,
        .bins = options.bins,
        .bin_names = duped_bin_names,
        .tests = options.tests,
        .test_names = duped_test_names,
        .deps = options.deps,
        .build_script = options.build_script,
        .exclude_roots = duped_exclude_roots,
    };

    var resolved_targets: std.ArrayList(ResolvedTarget) = .empty;
    errdefer {
        for (resolved_targets.items) |*rt| rt.deinit(allocator);
        resolved_targets.deinit(allocator);
    }

    var extra_lint_files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (extra_lint_files.items) |f| allocator.free(f);
        extra_lint_files.deinit(allocator);
    }

    var module_entry_roots_list: std.ArrayList([]const u8) = .empty;
    errdefer targeting.deinitOwnedPaths(allocator, &module_entry_roots_list);

    const path_mode: PathMode = if (options.positionals.len == 0)
        .project
    else if (options.positionals.len == 1)
        .module_root
    else
        .recursive;

    if (options.positionals.len > 0) {
        var explicit_targeting = targeting_options;
        explicit_targeting.apply_exclude_roots = false;

        for (options.positionals) |raw| {
            const resolved = try resolveUserPath(allocator, package.project_root, raw);
            errdefer allocator.free(resolved);

            switch (path_mode) {
                .module_root => try collectModuleRootLintFiles(
                    allocator,
                    io,
                    resolved,
                    explicit_targeting,
                    &extra_lint_files,
                    &module_entry_roots_list,
                ),
                .recursive => try collectRecursiveLintFiles(
                    allocator,
                    io,
                    resolved,
                    explicit_targeting,
                    &extra_lint_files,
                ),
                .project => unreachable,
            }
            allocator.free(resolved);
        }
    } else {
        var scanned = try build_scan.scanProjectBuildScript(allocator, io, package.project_root);
        defer if (scanned) |*s| s.deinit(allocator);

        if (scanned) |scan| {
            if (scan.targets.len > 0) {
                for (scan.targets) |t| {
                    if (targetNameExcluded(options.exclude_targets, t.name)) {
                        try resolved_targets.append(allocator, .{
                            .name = try allocator.dupe(u8, t.name),
                            .kind = t.kind,
                            .root_source_file = try allocator.dupe(u8, t.root_source_file),
                            .status = .skipped,
                            .reason = try allocator.dupe(u8, "Excluded by config exclude_targets"),
                            .files = &.{},
                        });
                        continue;
                    }
                    const matches = targeting.matchesTarget(targeting_options, t.name, t.kind);
                    if (!matches) {
                        try resolved_targets.append(allocator, .{
                            .name = try allocator.dupe(u8, t.name),
                            .kind = t.kind,
                            .root_source_file = try allocator.dupe(u8, t.root_source_file),
                            .status = .skipped,
                            .reason = try targeting.skipReason(allocator, options.color_profile, t.kind, targeting_options, t.name),
                            .files = &.{},
                        });
                    } else {
                        const abs_root = if (std.fs.path.isAbsolute(t.root_source_file))
                            try allocator.dupe(u8, t.root_source_file)
                        else
                            try std.fs.path.join(allocator, &.{ package.project_root, t.root_source_file });
                        defer allocator.free(abs_root);

                        if (!isReadableLocalFile(io, abs_root)) {
                            try resolved_targets.append(allocator, .{
                                .name = try allocator.dupe(u8, t.name),
                                .kind = t.kind,
                                .root_source_file = try allocator.dupe(u8, t.root_source_file),
                                .status = .skipped,
                                .reason = try allocator.dupe(u8, "Root source file is not readable/accessible"),
                                .files = &.{},
                            });
                        } else {
                            var reachable = try reach.collectReachablePublicFiles(allocator, io, abs_root);
                            defer reach.deinitOwnedPaths(allocator, &reachable);

                            var filtered: std.ArrayList([]const u8) = .empty;
                            errdefer {
                                for (filtered.items) |f| allocator.free(f);
                                filtered.deinit(allocator);
                            }

                            for (reachable.items) |path| {
                                if (!targeting.shouldSkipLintFile(path, targeting_options)) {
                                    try filtered.append(allocator, try allocator.dupe(u8, path));
                                }
                            }

                            if (filtered.items.len > 0) {
                                try resolved_targets.append(allocator, .{
                                    .name = try allocator.dupe(u8, t.name),
                                    .kind = t.kind,
                                    .root_source_file = try allocator.dupe(u8, t.root_source_file),
                                    .status = .linted,
                                    .reason = try allocator.dupe(u8, targeting.matchReason(t.kind)),
                                    .files = try filtered.toOwnedSlice(allocator),
                                });
                            } else {
                                try resolved_targets.append(allocator, .{
                                    .name = try allocator.dupe(u8, t.name),
                                    .kind = t.kind,
                                    .root_source_file = try allocator.dupe(u8, t.root_source_file),
                                    .status = .skipped,
                                    .reason = try allocator.dupe(u8, "All files excluded by filter (e.g., dependency)."),
                                    .files = &.{},
                                });
                            }
                        }
                    }
                }
            }
        }

        const build_zig_found_and_scanned = (scanned != null and scanned.?.targets.len > 0);

        if (!build_zig_found_and_scanned) {
            // Fallback to package paths
            var fallback_paths: std.ArrayList([]const u8) = .empty;
            defer {
                for (fallback_paths.items) |p| allocator.free(p);
                fallback_paths.deinit(allocator);
            }

            if (package.manifest_path) |manifest_path| {
                var loaded_paths = manifest.loadPackagePaths(allocator, io, manifest_path) catch |err| switch (err) {
                    error.ManifestPathsNotFound => blk: {
                        var fb = std.ArrayList([]const u8).empty;
                        try fb.append(allocator, try allocator.dupe(u8, "."));
                        break :blk fb;
                    },
                    else => return err,
                };
                defer {
                    for (loaded_paths.items) |p| allocator.free(p);
                    loaded_paths.deinit(allocator);
                }
                for (loaded_paths.items) |p| {
                    try fallback_paths.append(allocator, try allocator.dupe(u8, p));
                }
            } else {
                try fallback_paths.append(allocator, try allocator.dupe(u8, "."));
            }

            for (fallback_paths.items) |raw| {
                const resolved = if (std.fs.path.isAbsolute(raw))
                    try allocator.dupe(u8, raw)
                else
                    try std.fs.path.join(allocator, &.{ package.project_root, raw });
                errdefer allocator.free(resolved);

                const stat = std.Io.Dir.cwd().statFile(io, resolved, .{}) catch |err| switch (err) {
                    error.IsDir => {
                        var dir_files = try targeting.collectDirectoryLintTargets(allocator, io, resolved, targeting_options);
                        defer targeting.deinitOwnedPaths(allocator, &dir_files);
                        for (dir_files.items) |f| {
                            try extra_lint_files.append(allocator, try allocator.dupe(u8, f));
                        }
                        allocator.free(resolved);
                        continue;
                    },
                    else => {
                        allocator.free(resolved);
                        continue;
                    },
                };

                if (stat.kind == .directory) {
                    var dir_files = try targeting.collectDirectoryLintTargets(allocator, io, resolved, targeting_options);
                    defer targeting.deinitOwnedPaths(allocator, &dir_files);
                    for (dir_files.items) |f| {
                        try extra_lint_files.append(allocator, try allocator.dupe(u8, f));
                    }
                    allocator.free(resolved);
                } else {
                    if (!targeting.shouldSkipLintFile(resolved, targeting_options)) {
                        try extra_lint_files.append(allocator, resolved);
                    } else {
                        allocator.free(resolved);
                    }
                }
            }
        }

        if (targeting_options.build_script) {
            try collectBuildFiles(allocator, io, package.project_root, &extra_lint_files);
        }

        if (options.deps) {
            try appendDependencyLintFiles(allocator, io, duped_exclude_roots, targeting_options, &extra_lint_files);
        }
    }

    return Plan{
        .package = package,
        .resolved_targets = try resolved_targets.toOwnedSlice(allocator),
        .extra_lint_files = try extra_lint_files.toOwnedSlice(allocator),
        .path_mode = path_mode,
        .module_entry_roots = try module_entry_roots_list.toOwnedSlice(allocator),
        .targeting = targeting_options,
    };
}

fn appendDependencyLintFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    dependency_roots: []const []const u8,
    options: targeting.Options,
    extra_lint_files: *std.ArrayList([]const u8),
) !void {
    for (dependency_roots) |dep_root| {
        var dep_files = try targeting.collectDirectoryLintTargets(allocator, io, dep_root, options);
        defer targeting.deinitOwnedPaths(allocator, &dep_files);

        for (dep_files.items) |path| {
            if (targeting.containsPath(extra_lint_files.items, path)) continue;
            try extra_lint_files.append(allocator, try allocator.dupe(u8, path));
        }
    }
}

fn resolveUserPath(allocator: std.mem.Allocator, project_root: []const u8, raw: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(raw)) return try allocator.dupe(u8, raw);
    return try std.fs.path.join(allocator, &.{ project_root, raw });
}

fn collectModuleRootLintFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    resolved: []const u8,
    options: targeting.Options,
    extra: *std.ArrayList([]const u8),
    module_roots: *std.ArrayList([]const u8),
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, resolved, .{}) catch return;

    if (stat.kind == .directory) {
        var entrypoints: std.ArrayList([]const u8) = .empty;
        defer targeting.deinitOwnedPaths(allocator, &entrypoints);
        try targeting.collectDirectoryEntrypoints(allocator, io, resolved, options, &entrypoints);
        for (entrypoints.items) |entry| {
            try module_roots.append(allocator, try allocator.dupe(u8, entry));
        }

        var files = try targeting.collectDirectoryLintTargets(allocator, io, resolved, options);
        defer targeting.deinitOwnedPaths(allocator, &files);
        for (files.items) |path| {
            try extra.append(allocator, try allocator.dupe(u8, path));
        }
        return;
    }

    if (!std.mem.endsWith(u8, std.fs.path.basename(resolved), ".zig")) return;

    const abs = realPathFileAlloc(allocator, io, resolved) catch try allocator.dupe(u8, resolved);
    if (targeting.shouldSkipLintFile(abs, options)) {
        allocator.free(abs);
        return;
    }
    errdefer allocator.free(abs);
    try module_roots.append(allocator, abs);

    var reachable = try reach.collectReachablePublicFiles(allocator, io, abs);
    defer reach.deinitOwnedPaths(allocator, &reachable);

    for (reachable.items) |path| {
        if (targeting.shouldSkipLintFile(path, options)) continue;
        if (targeting.containsPath(extra.items, path)) continue;
        try extra.append(allocator, try allocator.dupe(u8, path));
    }
}

fn collectRecursiveLintFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    resolved: []const u8,
    options: targeting.Options,
    extra: *std.ArrayList([]const u8),
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, resolved, .{}) catch return;

    if (stat.kind == .directory) {
        try targeting.collectRecursiveZigFiles(allocator, io, resolved, options, extra);
        return;
    }

    if (!std.mem.endsWith(u8, std.fs.path.basename(resolved), ".zig")) return;

    const abs = realPathFileAlloc(allocator, io, resolved) catch try allocator.dupe(u8, resolved);
    if (targeting.shouldSkipLintFile(abs, options)) {
        allocator.free(abs);
        return;
    }
    try extra.append(allocator, abs);
}

fn targetNameExcluded(exclude_targets: []const []const u8, name: []const u8) bool {
    for (exclude_targets) |excluded| {
        if (std.mem.eql(u8, excluded, name)) return true;
    }
    return false;
}
