//! Builds filesystem-based lint plans used by `docent status` and check commands.

const std = @import("std");

const project_scan = @import("project_scan");
const targeting = project_scan.target;

const manifest = @import("manifest.zig");

/// How command-line paths select files to lint.
pub const PathMode = enum {
    /// No paths: recursively scan package paths from `build.zig.zon`.
    project,
    /// Explicit paths: recursively lint every eligible Zig file beneath them.
    recursive,
};

/// Inputs for `gather` (CLI flags and optional manifest override).
pub const Options = struct {
    /// When true, also lint path-dependency trees from `build.zig.zon` (`.path` entries only).
    deps: bool = false,
    /// When true with `deps`, scan only local dependency paths from the manifest.
    dependency_paths_only: bool = false,
    /// Explicit file or directory paths from the command line (empty uses project discovery).
    positionals: []const []const u8 = &.{},
    /// Filesystem paths excluded after discovery.
    exclude_paths: []const []const u8 = &.{},
    /// Whether selected paths are extended with package paths from `build.zig.zon`.
    inherit_manifest_paths: bool = true,
    /// When set, use this manifest instead of searching upward from cwd.
    manifest_path: ?[]const u8 = null,
};

/// Result of planning a lint run.
pub const Plan = struct {
    /// Package name, version, and roots from `build.zig.zon` when available.
    package: manifest.PackageMeta,
    /// Files to lint from explicit paths, manifest paths, or dependencies.
    extra_lint_files: []const []const u8,
    /// Raw package paths inherited from `build.zig.zon` for status display.
    manifest_paths: []const []const u8,
    /// Explicit CLI or configured include paths for status display.
    selected_paths: []const []const u8,
    /// How positional paths were interpreted.
    path_mode: PathMode,
    /// Resolved filesystem filters used while building this plan.
    targeting: targeting.Options,

    /// Frees all owned data in the plan.
    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        for (self.extra_lint_files) |path| allocator.free(path);
        allocator.free(self.extra_lint_files);
        for (self.manifest_paths) |path| allocator.free(path);
        allocator.free(self.manifest_paths);
        for (self.selected_paths) |path| allocator.free(path);
        allocator.free(self.selected_paths);
        for (self.targeting.exclude_roots) |root| allocator.free(root);
        allocator.free(self.targeting.exclude_roots);

        self.* = .{
            .package = .{ .project_root = "" },
            .extra_lint_files = &.{},
            .manifest_paths = &.{},
            .selected_paths = &.{},
            .path_mode = .project,
            .targeting = .{},
        };
    }
};

/// Resolves which files Docent would lint for the given options and project layout.
pub fn gather(allocator: std.mem.Allocator, io: std.Io, options: Options) !Plan {
    var package = if (options.manifest_path) |path|
        try manifest.loadPackageMeta(allocator, io, path)
    else
        try manifest.loadNearestPackageMeta(allocator, io);
    errdefer package.deinit(allocator);

    var exclude_roots: std.ArrayList([]const u8) = .empty;
    defer manifest.deinitOwnedPaths(allocator, &exclude_roots);
    if (package.manifest_path) |manifest_path| {
        exclude_roots = manifest.loadDependencyPathRoots(allocator, io, manifest_path) catch .empty;
    }

    const owned_exclude_roots = try duplicatePaths(allocator, exclude_roots.items);
    errdefer {
        for (owned_exclude_roots) |root| allocator.free(root);
        allocator.free(owned_exclude_roots);
    }
    const targeting_options: targeting.Options = .{
        .deps = options.deps,
        .exclude_roots = owned_exclude_roots,
    };

    var files: std.ArrayList([]const u8) = .empty;
    errdefer deinitPaths(allocator, &files);
    var manifest_paths: std.ArrayList([]const u8) = .empty;
    errdefer deinitPaths(allocator, &manifest_paths);
    var selected_paths: std.ArrayList([]const u8) = .empty;
    errdefer deinitPaths(allocator, &selected_paths);

    const path_mode: PathMode = if (options.dependency_paths_only or options.positionals.len > 0) .recursive else .project;

    if (!options.dependency_paths_only) {
        for (options.positionals) |raw| {
            const resolved = try resolveUserPath(allocator, package.project_root, raw);
            defer allocator.free(resolved);
            try selected_paths.append(allocator, try allocator.dupe(u8, resolved));

            var explicit_options = targeting_options;
            explicit_options.apply_exclude_roots = false;
            try collectPath(allocator, io, resolved, explicit_options, &files);
        }
    }

    if (!options.dependency_paths_only and options.inherit_manifest_paths) {
        var fallback_paths: std.ArrayList([]const u8) = .empty;
        defer deinitPaths(allocator, &fallback_paths);

        if (package.manifest_path) |manifest_path| {
            var loaded_paths = manifest.loadPackagePaths(allocator, io, manifest_path) catch |err| switch (err) {
                error.ManifestPathsNotFound => blk: {
                    var paths: std.ArrayList([]const u8) = .empty;
                    try paths.append(allocator, try allocator.dupe(u8, "."));
                    break :blk paths;
                },
                else => return err,
            };
            defer deinitPaths(allocator, &loaded_paths);
            for (loaded_paths.items) |path| {
                try fallback_paths.append(allocator, try allocator.dupe(u8, path));
                try manifest_paths.append(allocator, try allocator.dupe(u8, path));
            }
        } else {
            try fallback_paths.append(allocator, try allocator.dupe(u8, "."));
            try manifest_paths.append(allocator, try allocator.dupe(u8, "."));
        }

        for (fallback_paths.items) |raw| {
            const resolved = try resolveUserPath(allocator, package.project_root, raw);
            defer allocator.free(resolved);
            try collectPath(allocator, io, resolved, targeting_options, &files);
        }
    }

    if (options.deps) {
        if (options.dependency_paths_only) {
            for (owned_exclude_roots) |root| {
                try selected_paths.append(allocator, try allocator.dupe(u8, root));
            }
        }
        for (owned_exclude_roots) |root| {
            try collectPath(allocator, io, root, targeting_options, &files);
        }
    }

    filterExcludedFiles(allocator, package.project_root, options.exclude_paths, &files);

    return .{
        .package = package,
        .extra_lint_files = try files.toOwnedSlice(allocator),
        .manifest_paths = try manifest_paths.toOwnedSlice(allocator),
        .selected_paths = try selected_paths.toOwnedSlice(allocator),
        .path_mode = path_mode,
        .targeting = targeting_options,
    };
}

fn collectPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    options: targeting.Options,
    files: *std.ArrayList([]const u8),
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return;
    if (stat.kind == .directory) {
        var collected = try targeting.collectDirectoryLintTargets(allocator, io, path, options);
        defer targeting.deinitOwnedPaths(allocator, &collected);
        for (collected.items) |file| try appendUniquePath(allocator, files, file);
        return;
    }

    if (!std.mem.endsWith(u8, std.fs.path.basename(path), ".zig") or targeting.shouldSkipLintFile(path, options)) return;
    try appendUniquePath(allocator, files, path);
}

fn appendUniquePath(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), path: []const u8) !void {
    if (targeting.containsPath(paths.items, path)) return;
    try paths.append(allocator, try allocator.dupe(u8, path));
}

fn filterExcludedFiles(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    excludes: []const []const u8,
    files: *std.ArrayList([]const u8),
) void {
    var kept: usize = 0;
    for (files.items) |path| {
        var excluded = false;
        for (excludes) |raw| {
            const full = if (std.fs.path.isAbsolute(raw)) raw else std.fs.path.join(allocator, &.{ project_root, raw }) catch raw;
            defer if (full.ptr != raw.ptr) allocator.free(full);
            if (std.mem.startsWith(u8, path, full)) {
                excluded = true;
                break;
            }
        }
        if (excluded) {
            allocator.free(path);
        } else {
            files.items[kept] = path;
            kept += 1;
        }
    }
    files.items.len = kept;
}

fn resolveUserPath(allocator: std.mem.Allocator, project_root: []const u8, raw: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(raw)) return allocator.dupe(u8, raw);
    return std.fs.path.join(allocator, &.{ project_root, raw });
}

fn duplicatePaths(allocator: std.mem.Allocator, paths: []const []const u8) ![]const []const u8 {
    const owned = try allocator.alloc([]const u8, paths.len);
    errdefer allocator.free(owned);
    for (paths, 0..) |path, i| owned[i] = try allocator.dupe(u8, path);
    return owned;
}

fn deinitPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}
