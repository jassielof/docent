const std = @import("std");
const reachability = @import("Reachability.zig");

pub const Options = struct {
    include_build_scripts: bool = false,
};

/// Returns true when a path should be skipped by default lint targeting.
pub fn shouldSkipLintFile(path: []const u8, options: Options) bool {
    if (options.include_build_scripts) return false;
    return isBuildScriptPath(path);
}

/// Collects lint targets for a directory using entrypoint-aware behavior.
///
/// If `root.zig` exists, it is treated as the primary entrypoint.
/// Otherwise, all top-level `.zig` files in the directory are treated as
/// independent module entrypoints and expanded by public reachability.
///
/// If no top-level `.zig` files exist, the function falls back to recursively
/// collecting every `.zig` file under the directory.
pub fn collectDirectoryLintTargets(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    options: Options,
) !std.ArrayList([]const u8) {
    var targets: std.ArrayList([]const u8) = .empty;
    errdefer deinitOwnedPaths(allocator, &targets);

    var entrypoints: std.ArrayList([]const u8) = .empty;
    defer deinitOwnedPaths(allocator, &entrypoints);

    try collectDirectoryEntrypoints(allocator, dir_path, options, &entrypoints);

    if (entrypoints.items.len > 0) {
        for (entrypoints.items) |entrypoint| {
            var reachable = try reachability.collectReachablePublicFiles(allocator, entrypoint);
            defer reachability.deinitOwnedPaths(allocator, &reachable);

            for (reachable.items) |path| {
                if (shouldSkipLintFile(path, options)) continue;
                if (containsPath(targets.items, path)) continue;
                try targets.append(allocator, try allocator.dupe(u8, path));
            }
        }

        return targets;
    }

    try collectRecursiveZigFiles(allocator, dir_path, options, &targets);
    return targets;
}

pub fn deinitOwnedPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

fn collectDirectoryEntrypoints(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    options: Options,
    out: *std.ArrayList([]const u8),
) !void {
    const root_candidate = try std.fs.path.join(allocator, &.{ dir_path, "root.zig" });
    defer allocator.free(root_candidate);

    if (!shouldSkipLintFile(root_candidate, options) and isReadableLocalFile(root_candidate)) {
        const root_abs = std.fs.cwd().realpathAlloc(allocator, root_candidate) catch return;
        try out.append(allocator, root_abs);
        return;
    }

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(full);

        if (shouldSkipLintFile(full, options)) continue;

        const abs = std.fs.cwd().realpathAlloc(allocator, full) catch continue;
        try out.append(allocator, abs);
    }
}

fn collectRecursiveZigFiles(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    options: Options,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const full = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(full);

        if (shouldSkipLintFile(full, options)) continue;

        const abs = std.fs.cwd().realpathAlloc(allocator, full) catch continue;
        try out.append(allocator, abs);
    }
}

fn isReadableLocalFile(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

fn isBuildScriptPath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "build.zig")) return true;

    if (std.mem.indexOf(u8, path, "/build/") != null) return true;
    if (std.mem.indexOf(u8, path, "\\build\\") != null) return true;
    if (std.mem.startsWith(u8, path, "build/")) return true;
    if (std.mem.startsWith(u8, path, "build\\")) return true;

    return false;
}

fn containsPath(items: []const []const u8, needle: []const u8) bool {
    for (items) |it| {
        if (std.mem.eql(u8, it, needle)) return true;
    }
    return false;
}
