//! Selects which files and build targets Docent lints based on CLI flags and `build.zig` metadata.

const std = @import("std");
const reachability = @import("Reachability.zig");
const build_scan = @import("BuildScan.zig");
const carnaval = @import("carnaval");

fn realPathFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

/// CLI and build-step filters that control which sources are linted.
pub const Options = struct {
    /// When true, include library targets (default when no bin/test filters are set).
    lib: bool = false,
    /// When true, include all executable targets from `build.zig`.
    bins: bool = false,
    /// When non-empty, include only executables whose step name matches one of these strings.
    bin_names: []const []const u8 = &.{},
    /// When true, include all test targets from `build.zig`.
    tests: bool = false,
    /// When non-empty, include only tests whose step name matches one of these strings.
    test_names: []const []const u8 = &.{},

    /// When true, lint files under path dependencies instead of excluding them.
    deps: bool = false,
    /// When true, include `build.zig` and `build/*.zig` files.
    build_script: bool = false,

    /// Directory roots to skip (for example path-dependency trees).
    exclude_roots: []const []const u8 = &.{},

    /// Returns whether library targets should be linted for the current filter set.
    pub fn effectiveLib(self: Options) bool {
        if (self.lib) return true;
        if (self.bins or self.bin_names.len > 0 or self.tests or self.test_names.len > 0) return false;
        return true; // Default behavior
    }
};

/// Returns true when `a` and `b` refer to the same path (separator- and case-aware on Windows).
pub fn pathsEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (!pathSeparatorsEqual(ac, bc)) return false;
    }
    return true;
}

/// Returns true when `path` is the same as or nested under `root` (separator-aware).
pub fn isUnderExcludedRoot(path: []const u8, root: []const u8) bool {
    if (root.len == 0) return false;

    if (path.len >= root.len and pathComponentsEqual(path[0..root.len], root)) {
        if (path.len == root.len) return true;
        return pathSeparatorsEqual(path[root.len], '/');
    }

    if (path.len >= root.len and pathComponentsEqual(path[path.len - root.len ..], root)) {
        if (path.len == root.len) return true;
        return pathSeparatorsEqual(path[path.len - root.len - 1], '/');
    }

    return false;
}

fn pathComponentsEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (!pathSeparatorsEqual(ac, bc)) return false;
    }
    return true;
}

fn pathSeparatorsEqual(a: u8, b: u8) bool {
    const na: u8 = if (a == '\\') '/' else a;
    const nb: u8 = if (b == '\\') '/' else b;
    return na == nb;
}

/// Returns true when a path should be skipped by lint targeting.
pub fn shouldSkipLintFile(path: []const u8, options: Options) bool {
    if (!options.build_script and isBuildScriptPath(path)) return true;

    if (!options.deps) {
        for (options.exclude_roots) |root| {
            if (isUnderExcludedRoot(path, root)) return true;
        }
    }

    return false;
}

/// Collects lint targets for a directory using entrypoint-aware behavior.
pub fn collectDirectoryLintTargets(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    options: Options,
) !std.ArrayList([]const u8) {
    var targets: std.ArrayList([]const u8) = .empty;
    errdefer deinitOwnedPaths(allocator, &targets);

    var entrypoints: std.ArrayList([]const u8) = .empty;
    defer deinitOwnedPaths(allocator, &entrypoints);

    try collectDirectoryEntrypoints(allocator, io, dir_path, options, &entrypoints);

    if (entrypoints.items.len > 0) {
        for (entrypoints.items) |entrypoint| {
            var reachable = try reachability.collectReachablePublicFiles(allocator, io, entrypoint);
            defer reachability.deinitOwnedPaths(allocator, &reachable);

            for (reachable.items) |path| {
                if (shouldSkipLintFile(path, options)) continue;
                if (containsPath(targets.items, path)) continue;
                try targets.append(allocator, try allocator.dupe(u8, path));
            }
        }

        return targets;
    }

    try collectRecursiveZigFiles(allocator, io, dir_path, options, &targets);
    return targets;
}

/// Frees every owned path in `paths` and then deinits the list.
pub fn deinitOwnedPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

fn collectDirectoryEntrypoints(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    options: Options,
    out: *std.ArrayList([]const u8),
) !void {
    const root_candidate = try std.fs.path.join(allocator, &.{ dir_path, "root.zig" });
    defer allocator.free(root_candidate);

    if (isReadableLocalFile(io, root_candidate)) {
        const root_abs = realPathFileAlloc(allocator, io, root_candidate) catch return;
        if (!shouldSkipLintFile(root_abs, options)) {
            try out.append(allocator, root_abs);
        } else {
            allocator.free(root_abs);
        }
        return;
    }

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(full);

        const abs = realPathFileAlloc(allocator, io, full) catch continue;
        if (shouldSkipLintFile(abs, options)) {
            allocator.free(abs);
            continue;
        }
        try out.append(allocator, abs);
    }
}

fn collectRecursiveZigFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    options: Options,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const full = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(full);

        const abs = realPathFileAlloc(allocator, io, full) catch continue;
        if (shouldSkipLintFile(abs, options)) {
            allocator.free(abs);
            continue;
        }
        try out.append(allocator, abs);
    }
}

fn isReadableLocalFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// Returns whether `path` refers to a build script (`build.zig` or under `build/`).
pub fn isBuildScriptPath(path: []const u8) bool {
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

/// Returns whether a scanned build target matches the active targeting options.
pub fn matchesTarget(options: Options, name: []const u8, kind: build_scan.TargetKind) bool {
    return switch (kind) {
        .lib => options.effectiveLib(),
        .bin => blk: {
            if (options.bins) break :blk true;
            for (options.bin_names) |bin_name| {
                if (std.mem.eql(u8, bin_name, name)) break :blk true;
            }
            break :blk false;
        },
        .test_target => blk: {
            if (options.tests) break :blk true;
            for (options.test_names) |test_name| {
                if (std.mem.eql(u8, test_name, name)) break :blk true;
            }
            break :blk false;
        },
    };
}

/// Allocates a human-readable explanation for why a target was not linted.
pub fn skipReason(allocator: std.mem.Allocator, profile: carnaval.ColorProfile, kind: build_scan.TargetKind, options: Options, name: []const u8) ![]const u8 {
    return switch (kind) {
        .lib => try allocator.dupe(u8, "Libraries are not selected by active filters."),
        .bin => blk: {
            if (options.bin_names.len > 0) {
                const bin_flag = try carnaval.Style.init().italicized().underlined().renderAllocWithProfile("--bin", allocator, profile);
                defer allocator.free(bin_flag);
                break :blk try std.fmt.allocPrint(allocator, "Executable name does not match active {s} filters.", .{bin_flag});
            }
            const bins_styled = try carnaval.Style.init().underlined().renderAllocWithProfile("--bins", allocator, profile);
            defer allocator.free(bins_styled);

            const bin_raw = try std.fmt.allocPrint(allocator, "--bin {s}", .{name});
            defer allocator.free(bin_raw);
            const bin_styled = try carnaval.Style.init().underlined().renderAllocWithProfile(bin_raw, allocator, profile);
            defer allocator.free(bin_styled);

            break :blk try std.fmt.allocPrint(allocator, "Executables are opt-in (add {s} or {s}).", .{ bins_styled, bin_styled });
        },
        .test_target => blk: {
            if (options.test_names.len > 0) {
                const test_flag = try carnaval.Style.init().underlined().renderAllocWithProfile("--test", allocator, profile);
                defer allocator.free(test_flag);
                break :blk try std.fmt.allocPrint(allocator, "Test name does not match active {s} filters.", .{test_flag});
            }
            const tests_styled = try carnaval.Style.init().underlined().renderAllocWithProfile("--tests", allocator, profile);
            defer allocator.free(tests_styled);

            const test_raw = try std.fmt.allocPrint(allocator, "--test {s}", .{name});
            defer allocator.free(test_raw);
            const test_styled = try carnaval.Style.init().underlined().renderAllocWithProfile(test_raw, allocator, profile);
            defer allocator.free(test_styled);

            break :blk try std.fmt.allocPrint(allocator, "Tests are opt-in (add {s} or {s}).", .{ tests_styled, test_styled });
        },
    };
}

/// Returns a short explanation for why a target was included in the lint plan.
pub fn matchReason(kind: build_scan.TargetKind) []const u8 {
    return switch (kind) {
        .lib => "Selected by default (library surface).",
        .bin => "Selected by active filters (--bins / --bin).",
        .test_target => "Selected by active filters (--tests / --test).",
    };
}
