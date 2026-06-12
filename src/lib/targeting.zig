//! Selects which files and build targets Docent lints based on CLI flags and `build.zig` metadata.

const std = @import("std");
const build_scan = @import("build_scan.zig");
const reachability = @import("reachability.zig");
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
    /// When true, lint `build.zig` and every local file reachable from it via `@import`.
    build_script: bool = false,

    /// Directory roots to skip (for example path-dependency trees).
    exclude_roots: []const []const u8 = &.{},
    /// When false, `exclude_roots` are ignored (explicit CLI paths always lint).
    apply_exclude_roots: bool = true,

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

fn pathHasSegment(path: []const u8, segment: []const u8) bool {
    var rest = path;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, segment)) {
            const after = rest[segment.len..];
            if (after.len == 0 or pathSeparatorsEqual(after[0], '/')) return true;
        }
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse std.mem.indexOfScalar(u8, rest, '\\') orelse break;
        rest = rest[slash + 1 ..];
    }
    return false;
}

/// Returns true when a path should be skipped by lint targeting.
pub fn shouldSkipLintFile(path: []const u8, options: Options) bool {
    if (pathHasSegment(path, ".zig-cache") or pathHasSegment(path, "zig-out") or pathHasSegment(path, ".git")) return true;
    if (!options.build_script and isBuildScriptPath(path)) return true;

    if (options.apply_exclude_roots and !options.deps) {
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

fn tryAppendEntrypoint(
    allocator: std.mem.Allocator,
    io: std.Io,
    candidate: []const u8,
    options: Options,
    out: *std.ArrayList([]const u8),
) !bool {
    if (!isReadableLocalFile(io, candidate)) return false;
    const root_abs = realPathFileAlloc(allocator, io, candidate) catch return false;
    if (shouldSkipLintFile(root_abs, options)) {
        allocator.free(root_abs);
        return false;
    }
    try out.append(allocator, root_abs);
    return true;
}

/// Collects a package entry root or every top-level `.zig` file in `dir_path`.
pub fn collectDirectoryEntrypoints(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    options: Options,
    out: *std.ArrayList([]const u8),
) !void {
    const relative_roots = [_][]const u8{
        "root.zig",
        "src/lib/root.zig",
        "src/root.zig",
    };

    for (relative_roots) |relative_root| {
        const candidate = try std.fs.path.join(allocator, &.{ dir_path, relative_root });
        defer allocator.free(candidate);
        if (try tryAppendEntrypoint(allocator, io, candidate, options, out)) return;
    }

    var dir = std.Io.Dir.cwd().openDir(
        io,
        dir_path,
        .{
            .iterate = true,
        },
    ) catch return;
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

/// Recursively collects every `.zig` file under `dir_path` (zig fmt style).
pub fn collectRecursiveZigFiles(
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

/// Collects `build.zig` and the import closure rooted at it (when present under `project_root`).
pub fn collectBuildScriptLintFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const build_zig = try std.fs.path.join(allocator, &.{ project_root, "build.zig" });
    defer allocator.free(build_zig);

    if (!isReadableLocalFile(io, build_zig)) return;

    var reachable = try reachability.collectReachableFiles(allocator, io, build_zig);
    defer deinitOwnedPaths(allocator, &reachable);

    for (reachable.items) |path| {
        if (containsPath(out.items, path)) continue;
        try out.append(allocator, try allocator.dupe(u8, path));
    }
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

pub fn containsPath(items: []const []const u8, needle: []const u8) bool {
    for (items) |it| {
        if (pathsEqual(it, needle)) return true;
    }
    return false;
}

/// Owns canonical paths for deduplicating lint file visits across analysis passes.
pub const PathSet = struct {
    map: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) PathSet {
        return .{ .map = std.StringHashMap(void).init(allocator) };
    }

    pub fn deinit(self: *PathSet, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.map.deinit();
    }

    pub fn clear(self: *PathSet, allocator: std.mem.Allocator) void {
        var it = self.map.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        self.map.clearRetainingCapacity();
    }

    /// Returns `true` when `path` was already recorded.
    pub fn put(self: *PathSet, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
        const canonical = realPathFileAlloc(allocator, io, path) catch try allocator.dupe(u8, path);
        defer allocator.free(canonical);

        var it = self.map.keyIterator();
        while (it.next()) |existing| {
            if (pathsEqual(existing.*, canonical)) return true;
        }

        const owned = try allocator.dupe(u8, canonical);
        errdefer allocator.free(owned);
        const gop = try self.map.getOrPut(owned);
        if (gop.found_existing) {
            allocator.free(owned);
            return true;
        }
        return false;
    }
};

/// Returns `path` relative to `base`, or a copy of `path` when `path` is not under `base`.
pub fn pathRelativeTo(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]const u8 {
    if (path.len < base.len or !pathsEqual(path[0..base.len], base)) {
        return allocator.dupe(u8, path);
    }

    var rest = path[base.len..];
    if (rest.len > 0 and pathSeparatorsEqual(rest[0], '/')) {
        rest = rest[1..];
    }
    if (rest.len == 0) return allocator.dupe(u8, ".");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (rest) |c| {
        try out.append(allocator, if (c == '\\') '/' else c);
    }
    return try out.toOwnedSlice(allocator);
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

test "PathSet deduplicates canonical paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var set = PathSet.init(allocator);
    defer set.deinit(allocator);

    const first = try realPathFileAlloc(allocator, io, ".");
    defer allocator.free(first);

    try std.testing.expect(!try set.put(allocator, io, first));
    try std.testing.expect(try set.put(allocator, io, first));
}

test "artifact directories are skipped" {
    try std.testing.expect(shouldSkipLintFile("/project/.zig-cache/o/foo.zig", .{}));
    try std.testing.expect(shouldSkipLintFile("/project/zig-out/bin/app.zig", .{}));
    try std.testing.expect(!shouldSkipLintFile("/project/src/app.zig", .{}));
}

test "apply_exclude_roots controls dependency path skipping" {
    const path = "/project/modules/carnaval/src/lib/root.zig";
    const roots = &.{"/project/modules/carnaval"};
    const with_excludes: Options = .{ .exclude_roots = roots, .apply_exclude_roots = true };
    const explicit: Options = .{ .exclude_roots = roots, .apply_exclude_roots = false };
    try std.testing.expect(shouldSkipLintFile(path, with_excludes));
    try std.testing.expect(!shouldSkipLintFile(path, explicit));
}
