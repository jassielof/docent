//! Discovers `.path`-based dependencies from `build.zig.zon`, for bundling
//! into a package's own `docs.json` as appendix modules -- see
//! `src/cli/commands/typeset.zig`'s `--deps` / `--deps-recursive` flags.
//!
//! Deliberately `.path`-only, matching the same restriction `docent`'s own
//! lint-target `--deps` flag already uses elsewhere (`status_plan.zig`,
//! `scan/target.zig`): a `.path` dependency is vendored locally, so finding
//! its root module is just a directory-convention lookup. A URL/hash
//! dependency lives in the global package cache under a hash-derived path
//! that isn't resolvable without replicating the build system's fetch/lock
//! resolution -- out of scope here.

const std = @import("std");

const docent = @import("docent");
const target = docent.scan.target;

pub const Entry = struct {
    /// The `.dependencies.<name>` key from build.zig.zon.
    name: []const u8,
    /// Resolved absolute directory the dependency lives in.
    root_dir: []const u8,
};

/// Scans `.dependencies = .{ .name = .{ .path = "..." }, ... }` for `.path`
/// entries, resolved relative to `manifest_path`'s directory. Ignores
/// URL/hash dependencies (no `.path` field) entirely.
pub fn discover(allocator: std.mem.Allocator, io: std.Io, manifest_path: []const u8) !std.ArrayList(Entry) {
    const dir = std.fs.path.dirname(manifest_path) orelse return error.InvalidManifestPath;

    const file = try std.Io.Dir.cwd().openFile(io, manifest_path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const manifest_text = try reader.interface.allocRemaining(allocator, .limited(1 * 1024 * 1024));
    defer allocator.free(manifest_text);

    var out: std.ArrayList(Entry) = .empty;
    errdefer deinitEntries(allocator, &out);

    const deps_idx = std.mem.indexOf(u8, manifest_text, ".dependencies") orelse return out;
    var i = deps_idx + ".dependencies".len;
    while (i < manifest_text.len and manifest_text[i] != '{') : (i += 1) {}
    if (i >= manifest_text.len) return out;
    i += 1;

    var depth: usize = 1;
    var current_name: ?[]const u8 = null;

    while (i < manifest_text.len and depth > 0) {
        if (manifest_text[i] == '/' and i + 1 < manifest_text.len and manifest_text[i + 1] == '/') {
            i += 2;
            while (i < manifest_text.len and manifest_text[i] != '\n') : (i += 1) {}
            continue;
        }

        if (depth == 1 and manifest_text[i] == '.') {
            const start = i + 1;
            var j = start;
            while (j < manifest_text.len and (std.ascii.isAlphanumeric(manifest_text[j]) or manifest_text[j] == '_')) : (j += 1) {}
            if (j > start) {
                current_name = manifest_text[start..j];
                i = j;
                continue;
            }
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

            const raw_path = manifest_text[start..j];
            if (raw_path.len > 0 and current_name != null) {
                const joined = if (std.fs.path.isAbsolute(raw_path))
                    try allocator.dupe(u8, raw_path)
                else
                    try std.fs.path.join(allocator, &.{ dir, raw_path });
                defer allocator.free(joined);

                const resolved = realPathOrDupe(allocator, io, joined);
                try out.append(allocator, .{
                    .name = try allocator.dupe(u8, current_name.?),
                    .root_dir = resolved,
                });
            }
            i = j + 1;
            continue;
        }

        if (manifest_text[i] == '{') depth += 1;
        if (manifest_text[i] == '}') {
            depth -= 1;
            if (depth == 1) current_name = null;
        }
        i += 1;
    }

    return out;
}

/// Like `discover`, but also walks each dependency's own `build.zig.zon`
/// for nested `.path` deps (e.g. vereda → xdg). Deduplicates by resolved
/// `root_dir`. Still never follows URL/hash dependencies.
pub fn discoverRecursive(allocator: std.mem.Allocator, io: std.Io, manifest_path: []const u8) !std.ArrayList(Entry) {
    var out: std.ArrayList(Entry) = .empty;
    errdefer deinitEntries(allocator, &out);

    var seen_dirs: std.StringHashMap(void) = .init(allocator);
    defer seen_dirs.deinit();

    var queue: std.ArrayList([]const u8) = .empty;
    defer {
        for (queue.items) |p| allocator.free(p);
        queue.deinit(allocator);
    }

    try queue.append(allocator, try allocator.dupe(u8, manifest_path));

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);
        defer allocator.free(current);

        var direct = try discover(allocator, io, current);
        defer deinitEntries(allocator, &direct);

        for (direct.items) |dep| {
            if (seen_dirs.contains(dep.root_dir)) continue;

            const name = try allocator.dupe(u8, dep.name);
            errdefer allocator.free(name);
            const root_dir = try allocator.dupe(u8, dep.root_dir);
            errdefer allocator.free(root_dir);

            try seen_dirs.put(root_dir, {});
            try out.append(allocator, .{ .name = name, .root_dir = root_dir });

            const nested_manifest = try std.fs.path.join(allocator, &.{ root_dir, "build.zig.zon" });
            defer allocator.free(nested_manifest);
            if (fileExists(io, nested_manifest)) {
                try queue.append(allocator, try allocator.dupe(u8, nested_manifest));
            }
        }
    }

    return out;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// Finds the conventional module root inside a dependency's directory
/// (`root.zig`, `src/lib/root.zig`, or `src/root.zig` -- see
/// `docent.scan.target`'s `collectDirectoryEntrypoints`). Returns `null`
/// when none of those conventions match, rather than guessing from
/// whatever `.zig` files happen to sit at the top level.
pub fn findRootModule(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !?[]const u8 {
    var entrypoints: std.ArrayList([]const u8) = .empty;
    defer target.deinitOwnedPaths(allocator, &entrypoints);

    try target.collectDirectoryEntrypoints(allocator, io, dir, .{}, &entrypoints);

    for (entrypoints.items) |entry| {
        const base = std.fs.path.basename(entry);
        if (std.mem.eql(u8, base, "root.zig")) {
            return try allocator.dupe(u8, entry);
        }
    }
    return null;
}

fn realPathOrDupe(allocator: std.mem.Allocator, io: std.Io, path: []const u8) []const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(io, path, &buffer) catch return allocator.dupe(u8, path) catch path;
    return allocator.dupe(u8, buffer[0..len]) catch path;
}

pub fn deinitEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(Entry)) void {
    for (entries.items) |e| {
        allocator.free(e.name);
        allocator.free(e.root_dir);
    }
    entries.deinit(allocator);
}
