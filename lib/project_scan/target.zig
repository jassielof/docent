//! Selects filesystem paths Docent lints.

const std = @import("std");

fn realPathFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

/// Filesystem filters that control which sources are linted.
pub const Options = struct {
    /// When true, lint files under path dependencies instead of excluding them.
    deps: bool = false,
    /// When true, lint `build.zig` and files below `build/` during the directory walk.
    build_script: bool = false,
    /// Directory roots to skip (for example path-dependency trees).
    exclude_roots: []const []const u8 = &.{},
    /// When false, `exclude_roots` are ignored (explicit CLI paths always lint).
    apply_exclude_roots: bool = true,
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
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse
            std.mem.indexOfScalar(u8, rest, '\\') orelse break;
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

/// Collects every eligible Zig file below a directory.
pub fn collectDirectoryLintTargets(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    options: Options,
) !std.ArrayList([]const u8) {
    var targets: std.ArrayList([]const u8) = .empty;
    errdefer deinitOwnedPaths(allocator, &targets);
    try collectRecursiveZigFiles(allocator, io, dir_path, options, &targets);
    return targets;
}

/// Frees every owned path in `paths` and then deinits the list.
pub fn deinitOwnedPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

/// Recursively collects every `.zig` file under `dir_path`.
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
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;

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

/// Returns whether `path` refers to a build script (`build.zig` or under `build/`).
pub fn isBuildScriptPath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "build.zig")) return true;
    return std.mem.indexOf(u8, path, "/build/") != null or
        std.mem.indexOf(u8, path, "\\build\\") != null or
        std.mem.startsWith(u8, path, "build/") or
        std.mem.startsWith(u8, path, "build\\");
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
        while (it.next()) |key| allocator.free(key.*);
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
pub fn pathRelativeTo(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    if (path.len < base.len or !pathsEqual(path[0..base.len], base)) return allocator.dupe(u8, path);

    var rest = path[base.len..];
    if (rest.len > 0 and pathSeparatorsEqual(rest[0], '/')) rest = rest[1..];
    if (rest.len == 0) return allocator.dupe(u8, ".");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (rest) |c| try out.append(allocator, if (c == '\\') '/' else c);
    return try out.toOwnedSlice(allocator);
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
