const std = @import("std");

pub const Result = struct {
    dependencies: []const []const u8,
    root_sources: []const []const u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.dependencies) |s| allocator.free(s);
        allocator.free(self.dependencies);
        for (self.root_sources) |s| allocator.free(s);
        allocator.free(self.root_sources);
        self.* = .{ .dependencies = &.{}, .root_sources = &.{} };
    }
};

/// Heuristic text scan of `build.zig` for dependency names and `root_source_file` paths.
pub fn scanBuildScript(allocator: std.mem.Allocator, build_text: []const u8) !Result {
    var deps: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (deps.items) |s| allocator.free(s);
        deps.deinit(allocator);
    }

    var roots: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (roots.items) |s| allocator.free(s);
        roots.deinit(allocator);
    }

    const dep_needle = "b.dependency(\"";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, build_text, i, dep_needle)) |idx| {
        const start = idx + dep_needle.len;
        const end = std.mem.indexOfPos(u8, build_text, start, "\"") orelse break;
        const name = build_text[start..end];
        if (name.len > 0 and !containsStr(deps.items, name)) {
            try deps.append(allocator, try allocator.dupe(u8, name));
        }
        i = end + 1;
    }

    const root_needle = "root_source_file = b.path(\"";
    i = 0;
    while (std.mem.indexOfPos(u8, build_text, i, root_needle)) |idx| {
        const start = idx + root_needle.len;
        const end = std.mem.indexOfPos(u8, build_text, start, "\"") orelse break;
        const path = build_text[start..end];
        if (path.len > 0 and !containsStr(roots.items, path)) {
            try roots.append(allocator, try allocator.dupe(u8, path));
        }
        i = end + 1;
    }

    return .{
        .dependencies = try deps.toOwnedSlice(allocator),
        .root_sources = try roots.toOwnedSlice(allocator),
    };
}

/// Reads and scans `build.zig` at `project_root/build.zig` when present.
pub fn scanProjectBuildScript(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8) !?Result {
    const build_path = try std.fs.path.join(allocator, &.{ project_root, "build.zig" });
    defer allocator.free(build_path);

    const build_text = std.Io.Dir.cwd().readFileAlloc(io, build_path, allocator, .limited(2 * 1024 * 1024)) catch return null;
    defer allocator.free(build_text);

    return try scanBuildScript(allocator, build_text);
}

fn containsStr(items: []const []const u8, needle: []const u8) bool {
    for (items) |it| {
        if (std.mem.eql(u8, it, needle)) return true;
    }
    return false;
}
