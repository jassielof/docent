const std = @import("std");
const carnaval = @import("carnaval");

const manifest = @import("Manifest.zig");
const targeting = @import("Targeting.zig");
const build_scan = @import("BuildScan.zig");
const reachability = @import("Reachability.zig");

pub const ResolvedTarget = struct {
    name: []const u8,
    kind: build_scan.TargetKind,
    root_source_file: []const u8,
    status: enum { linted, skipped },
    reason: []const u8,
    files: []const []const u8,

    pub fn deinit(self: *ResolvedTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.root_source_file);
        allocator.free(self.reason);
        for (self.files) |f| allocator.free(f);
        allocator.free(self.files);
    }
};

pub const Options = struct {
    lib: bool = false,
    bins: bool = false,
    bin_names: []const []const u8 = &.{},
    tests: bool = false,
    test_names: []const []const u8 = &.{},

    deps: bool = false,
    build_script: bool = false,

    positionals: []const []const u8 = &.{},
    /// When set, use this manifest instead of searching upward from cwd.
    manifest_path: ?[]const u8 = null,
    color_profile: carnaval.ColorProfile = .none,
};

pub const Plan = struct {
    package: manifest.PackageMeta,
    resolved_targets: []ResolvedTarget,
    extra_lint_files: []const []const u8,
    explicit_paths: bool,
    targeting: targeting.Options,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        for (self.resolved_targets) |*rt| rt.deinit(allocator);
        allocator.free(self.resolved_targets);
        for (self.extra_lint_files) |f| allocator.free(f);
        allocator.free(self.extra_lint_files);

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
            .explicit_paths = false,
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
    const build_zig = try std.fs.path.join(allocator, &.{ project_root, "build.zig" });
    errdefer allocator.free(build_zig);

    if (isReadableLocalFile(io, build_zig)) {
        const abs = try realPathFileAlloc(allocator, io, build_zig);
        allocator.free(build_zig);
        try out.append(allocator, abs);
    } else {
        allocator.free(build_zig);
    }

    const build_dir = try std.fs.path.join(allocator, &.{ project_root, "build" });
    defer allocator.free(build_dir);

    var dir = std.Io.Dir.cwd().openDir(io, build_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const full = try std.fs.path.join(allocator, &.{ build_dir, entry.path });
        defer allocator.free(full);

        const abs = try realPathFileAlloc(allocator, io, full);
        try out.append(allocator, abs);
    }
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

    var explicit_paths = false;

    if (options.positionals.len > 0) {
        explicit_paths = true;
        for (options.positionals) |raw| {
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
    } else {
        var scanned = try build_scan.scanProjectBuildScript(allocator, io, package.project_root);
        defer if (scanned) |*s| s.deinit(allocator);

        if (scanned) |scan| {
            if (scan.targets.len > 0) {
                for (scan.targets) |t| {
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
                            var reachable = try reachability.collectReachablePublicFiles(allocator, io, abs_root);
                            defer reachability.deinitOwnedPaths(allocator, &reachable);

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
    }

    return Plan{
        .package = package,
        .resolved_targets = try resolved_targets.toOwnedSlice(allocator),
        .extra_lint_files = try extra_lint_files.toOwnedSlice(allocator),
        .explicit_paths = explicit_paths,
        .targeting = targeting_options,
    };
}
