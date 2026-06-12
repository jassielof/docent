//! Shared project-root file presence checks for score categories.

const std = @import("std");

/// Result of scanning a project root for expected files.
pub const Report = struct {
    /// Whether a core file variant was found.
    core_found: bool = false,
    /// Basename of the matched core file when found.
    core_name: ?[]const u8 = null,
    /// Basenames of matched optional files.
    extras: []const []const u8 = &.{},

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        if (self.core_name) |name| allocator.free(name);
        for (self.extras) |extra| allocator.free(extra);
        allocator.free(self.extras);
        self.* = .{};
    }
};

fn isReadableFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// Scans `project_root` for the first existing `core_variants` file and any `extra_variants`.
pub fn scan(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    core_variants: []const []const u8,
    extra_variants: []const []const u8,
) !Report {
    var report: Report = .{};
    errdefer report.deinit(allocator);

    var extras: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (extras.items) |name| allocator.free(name);
        extras.deinit(allocator);
    }

    for (core_variants) |variant| {
        const candidate = try std.fs.path.join(allocator, &.{ project_root, variant });
        defer allocator.free(candidate);
        if (isReadableFile(io, candidate)) {
            report.core_found = true;
            report.core_name = try allocator.dupe(u8, variant);
            break;
        }
    }

    for (extra_variants) |variant| {
        const candidate = try std.fs.path.join(allocator, &.{ project_root, variant });
        defer allocator.free(candidate);
        if (isReadableFile(io, candidate)) {
            try extras.append(allocator, try allocator.dupe(u8, variant));
        }
    }

    report.extras = try extras.toOwnedSlice(allocator);
    return report;
}

test "scan finds core and extras" {
    const io = std.testing.io;
    const root = "tests/fixtures/scenarios/manifest_with_deps";
    const report = try scan(
        std.testing.allocator,
        io,
        root,
        &.{ "README.md", "README" },
        &.{ "LICENSE", "CONTRIBUTING.md" },
    );
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(!report.core_found or report.core_name != null);
}
