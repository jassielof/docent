const std = @import("std");

const manifest = @import("Manifest.zig");
const targeting = @import("Targeting.zig");

pub const EntrypointMode = enum {
    root_zig,
    top_level_modules,
    recursive,
};

pub const Options = struct {
    include_build_scripts: bool = false,
    lint_dependencies: bool = false,
    positionals: []const []const u8 = &.{},
    /// When set, use this manifest instead of searching upward from cwd.
    manifest_path: ?[]const u8 = null,
};

pub const RootSummary = struct {
    path: []const u8,
    mode: EntrypointMode,
    targets: []const []const u8,

    pub fn targetCount(self: RootSummary) usize {
        return self.targets.len;
    }

    pub fn deinit(self: *RootSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.targets) |t| allocator.free(t);
        allocator.free(self.targets);
        self.* = .{ .path = "", .mode = .recursive, .targets = &.{} };
    }
};

pub const Plan = struct {
    package: manifest.PackageMeta,
    lint_roots: []RootSummary,
    excluded_dependency_roots: []const []const u8,
    targeting: targeting.Options,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        for (self.lint_roots) |*root| root.deinit(allocator);
        allocator.free(self.lint_roots);
        for (self.excluded_dependency_roots) |p| allocator.free(p);
        allocator.free(self.excluded_dependency_roots);
        self.* = .{
            .package = .{ .project_root = "" },
            .lint_roots = &.{},
            .excluded_dependency_roots = &.{},
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

fn detectEntrypointMode(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) EntrypointMode {
    const root_candidate = std.fs.path.join(allocator, &.{ dir_path, "root.zig" }) catch return .recursive;
    defer allocator.free(root_candidate);

    if (isReadableLocalFile(io, root_candidate)) return .root_zig;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return .recursive;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch return .recursive) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            return .top_level_modules;
        }
    }

    return .recursive;
}

fn gatherRootSummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    targeting_options: targeting.Options,
) !RootSummary {
    const stat = std.Io.Dir.cwd().statFile(io, root_path, .{}) catch |err| switch (err) {
        error.IsDir => return try gatherDirectorySummary(allocator, io, root_path, targeting_options),
        else => return error.RootInaccessible,
    };

    if (stat.kind == .directory) {
        return try gatherDirectorySummary(allocator, io, root_path, targeting_options);
    }

    if (!std.mem.endsWith(u8, root_path, ".zig")) {
        return RootSummary{
            .path = try allocator.dupe(u8, root_path),
            .mode = .recursive,
            .targets = &.{},
        };
    }

    if (targeting.shouldSkipLintFile(root_path, targeting_options)) {
        return RootSummary{
            .path = try allocator.dupe(u8, root_path),
            .mode = .recursive,
            .targets = &.{},
        };
    }

    const abs = realPathFileAlloc(allocator, io, root_path) catch try allocator.dupe(u8, root_path);
    const targets = try allocator.alloc([]const u8, 1);
    targets[0] = abs;

    return .{
        .path = try allocator.dupe(u8, root_path),
        .mode = .recursive,
        .targets = targets,
    };
}

fn gatherDirectorySummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    targeting_options: targeting.Options,
) !RootSummary {
    const mode = detectEntrypointMode(allocator, io, dir_path);

    var collected = try targeting.collectDirectoryLintTargets(allocator, io, dir_path, targeting_options);
    errdefer targeting.deinitOwnedPaths(allocator, &collected);

    const targets = try collected.toOwnedSlice(allocator);
    collected = .empty;

    return .{
        .path = try allocator.dupe(u8, dir_path),
        .mode = mode,
        .targets = targets,
    };
}

pub fn gather(allocator: std.mem.Allocator, io: std.Io, options: Options) !Plan {
    var package: manifest.PackageMeta = undefined;
    if (options.manifest_path) |mp| {
        package = try manifest.loadPackageMeta(allocator, io, mp);
    } else {
        package = try manifest.loadNearestPackageMeta(allocator, io);
    }
    errdefer package.deinit(allocator);

    var exclude_roots: std.ArrayList([]const u8) = .empty;
    errdefer manifest.deinitOwnedPaths(allocator, &exclude_roots);

    if (package.manifest_path) |manifest_path| {
        exclude_roots = manifest.loadDependencyPathRoots(allocator, io, manifest_path) catch .empty;
    }

    const targeting_options: targeting.Options = .{
        .include_build_scripts = options.include_build_scripts,
        .lint_dependencies = options.lint_dependencies,
        .exclude_roots = if (options.lint_dependencies) &.{} else exclude_roots.items,
    };

    var lint_root_paths: std.ArrayList([]const u8) = .empty;
    errdefer manifest.deinitOwnedPaths(allocator, &lint_root_paths);

    if (options.positionals.len > 0) {
        for (options.positionals) |raw| {
            const resolved = if (std.fs.path.isAbsolute(raw))
                try allocator.dupe(u8, raw)
            else
                try std.fs.path.join(allocator, &.{ package.project_root, raw });
            try lint_root_paths.append(allocator, resolved);
        }
    } else if (package.manifest_path) |manifest_path| {
        lint_root_paths = manifest.loadPackagePaths(allocator, io, manifest_path) catch |err| switch (err) {
            error.ManifestPathsNotFound => blk: {
                var fallback: std.ArrayList([]const u8) = .empty;
                const cwd = try realPathFileAlloc(allocator, io, ".");
                try fallback.append(allocator, cwd);
                break :blk fallback;
            },
            else => return err,
        };
    } else {
        const cwd = try realPathFileAlloc(allocator, io, ".");
        try lint_root_paths.append(allocator, cwd);
    }

    var summaries: std.ArrayList(RootSummary) = .empty;
    errdefer {
        for (summaries.items) |*s| s.deinit(allocator);
        summaries.deinit(allocator);
    }

    for (lint_root_paths.items) |root_path| {
        const summary = gatherRootSummary(allocator, io, root_path, targeting_options) catch |err| switch (err) {
            error.RootInaccessible => continue,
            else => return err,
        };
        try summaries.append(allocator, summary);
    }

    manifest.deinitOwnedPaths(allocator, &lint_root_paths);

    const excluded_owned = if (options.lint_dependencies)
        try allocator.alloc([]const u8, 0)
    else
        try exclude_roots.toOwnedSlice(allocator);

    if (exclude_roots.items.len > 0) {
        manifest.deinitOwnedPaths(allocator, &exclude_roots);
    }

    return .{
        .package = package,
        .lint_roots = try summaries.toOwnedSlice(allocator),
        .excluded_dependency_roots = excluded_owned,
        .targeting = targeting_options,
    };
}

pub const Error = error{
    RootInaccessible,
    OutOfMemory,
};
