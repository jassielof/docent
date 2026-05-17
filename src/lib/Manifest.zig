const std = @import("std");

const PathsManifest = struct {
    paths: ?[]const []const u8 = null,
};

fn realPathFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

fn isReadableFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// Walks upward from cwd until a readable `build.zig.zon` is found.
pub fn findNearestManifestPath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var current = try realPathFileAlloc(allocator, io, ".");

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, "build.zig.zon" });
        if (isReadableFile(io, candidate)) {
            allocator.free(current);
            return candidate;
        }
        allocator.free(candidate);

        const parent_opt = std.fs.path.dirname(current);
        if (parent_opt == null) {
            allocator.free(current);
            return error.ManifestNotFound;
        }

        const parent = parent_opt.?;
        if (parent.len == current.len) {
            allocator.free(current);
            return error.ManifestNotFound;
        }

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

fn readManifestText(allocator: std.mem.Allocator, io: std.Io, manifest_path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, manifest_path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(1 * 1024 * 1024));
}

fn manifestDir(manifest_path: []const u8) ![]const u8 {
    return std.fs.path.dirname(manifest_path) orelse error.InvalidManifestPath;
}

/// Scans `.dependencies = .{ ... }` for `.path = "..."` entries (zon text).
fn scanDependencyPathStrings(allocator: std.mem.Allocator, manifest_text: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer deinitOwnedPaths(allocator, &out);

    const deps_idx = std.mem.indexOf(u8, manifest_text, ".dependencies") orelse return out;
    var i = deps_idx + ".dependencies".len;

    while (i < manifest_text.len and manifest_text[i] != '{') : (i += 1) {}
    if (i >= manifest_text.len) return out;

    i += 1;
    var depth: usize = 1;

    while (i < manifest_text.len and depth > 0) {
        if (manifest_text[i] == '/' and i + 1 < manifest_text.len and manifest_text[i + 1] == '/') {
            i += 2;
            while (i < manifest_text.len and manifest_text[i] != '\n') : (i += 1) {}
            continue;
        }

        if (depth >= 1 and std.mem.startsWith(u8, manifest_text[i..], ".path")) {
            var j = i + ".path".len;
            while (j < manifest_text.len and manifest_text[j] != '=') : (j += 1) {}
            if (j >= manifest_text.len) break;
            j += 1;
            while (j < manifest_text.len and std.ascii.isWhitespace(manifest_text[j])) : (j += 1) {}
            if (j >= manifest_text.len or manifest_text[j] != '"') {
                i += 1;
                continue;
            }
            const start = j + 1;
            j += 1;
            var escaped = false;
            while (j < manifest_text.len) : (j += 1) {
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (manifest_text[j] == '\\') {
                    escaped = true;
                    continue;
                }
                if (manifest_text[j] == '"') break;
            }
            if (j >= manifest_text.len) break;

            const raw = manifest_text[start..j];
            if (raw.len > 0) {
                try out.append(allocator, try allocator.dupe(u8, raw));
            }
            i = j + 1;
            continue;
        }

        if (manifest_text[i] == '{') depth += 1;
        if (manifest_text[i] == '}') depth -= 1;
        i += 1;
    }

    return out;
}

/// Resolves `.paths` entries from `build.zig.zon` relative to the manifest directory.
pub fn loadPackagePaths(allocator: std.mem.Allocator, io: std.Io, manifest_path: []const u8) !std.ArrayList([]const u8) {
    const manifest_text = try readManifestText(allocator, io, manifest_path);
    defer allocator.free(manifest_text);

    const source = try allocator.dupeZ(u8, manifest_text);
    defer allocator.free(source);

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(allocator);

    const manifest = try std.zon.parse.fromSliceAlloc(
        PathsManifest,
        allocator,
        source,
        &diag,
        .{
            .ignore_unknown_fields = true,
            .free_on_error = true,
        },
    );
    defer std.zon.parse.free(allocator, manifest);

    const dir = try manifestDir(manifest_path);
    const paths_field = manifest.paths orelse return error.ManifestPathsNotFound;

    var out: std.ArrayList([]const u8) = .empty;
    errdefer deinitOwnedPaths(allocator, &out);

    for (paths_field) |raw| {
        if (raw.len == 0) continue;
        const resolved = if (std.fs.path.isAbsolute(raw))
            try allocator.dupe(u8, raw)
        else
            try std.fs.path.join(allocator, &.{ dir, raw });
        try out.append(allocator, resolved);
    }

    return out;
}

/// Collects resolved directory roots for every `.dependencies.*.path` in `build.zig.zon`.
pub fn loadDependencyPathRoots(allocator: std.mem.Allocator, io: std.Io, manifest_path: []const u8) !std.ArrayList([]const u8) {
    const manifest_text = try readManifestText(allocator, io, manifest_path);
    defer allocator.free(manifest_text);

    const dir = try manifestDir(manifest_path);
    var raw_paths = try scanDependencyPathStrings(allocator, manifest_text);
    defer deinitOwnedPaths(allocator, &raw_paths);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer deinitOwnedPaths(allocator, &out);

    for (raw_paths.items) |raw| {
        const joined = if (std.fs.path.isAbsolute(raw))
            try allocator.dupe(u8, raw)
        else
            try std.fs.path.join(allocator, &.{ dir, raw });

        const normalized = realPathFileAlloc(allocator, io, joined) catch joined;
        if (joined.ptr != normalized.ptr) allocator.free(joined);

        try out.append(allocator, normalized);
    }

    return out;
}

/// Convenience: nearest manifest package paths (same as CLI default targets).
pub fn loadNearestPackagePaths(allocator: std.mem.Allocator, io: std.Io) !std.ArrayList([]const u8) {
    const manifest_path = try findNearestManifestPath(allocator, io);
    defer allocator.free(manifest_path);
    return loadPackagePaths(allocator, io, manifest_path);
}

/// Convenience: dependency path roots for the nearest manifest.
pub fn loadNearestDependencyPathRoots(allocator: std.mem.Allocator, io: std.Io) !std.ArrayList([]const u8) {
    const manifest_path = try findNearestManifestPath(allocator, io);
    defer allocator.free(manifest_path);
    return loadDependencyPathRoots(allocator, io, manifest_path);
}

pub fn deinitOwnedPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

pub const Error = error{
    ManifestNotFound,
    InvalidManifestPath,
    ManifestPathsNotFound,
};
