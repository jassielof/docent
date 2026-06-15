//! `zig fmt --check` formatting score.

const std = @import("std");
const targeting = @import("../scan/target.zig");

pub const Report = struct {
    total_files: usize = 0,
    failed_files: []const []const u8 = &.{},
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.failed_files) |path| allocator.free(path);
        allocator.free(self.failed_files);
        if (self.error_message) |msg| allocator.free(msg);
        self.* = .{};
    }
};

fn realPathFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

fn isFormatCandidate(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zon");
}

fn collectFormatPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    for (paths) |raw| {
        const stat = std.Io.Dir.cwd().statFile(io, raw, .{}) catch continue;
        if (stat.kind == .directory) {
            try targeting.collectRecursiveZigFiles(allocator, io, raw, .{}, out);
            continue;
        }
        if (!isFormatCandidate(raw)) continue;
        const abs = realPathFileAlloc(allocator, io, raw) catch try allocator.dupe(u8, raw);
        if (targeting.containsPath(out.items, abs)) {
            allocator.free(abs);
            continue;
        }
        try out.append(allocator, abs);
    }
}

/// Runs `zig fmt --check` on `paths` and returns formatting results.
pub fn check(allocator: std.mem.Allocator, io: std.Io, paths: []const []const u8) !Report {
    var candidates: std.ArrayList([]const u8) = .empty;
    defer targeting.deinitOwnedPaths(allocator, &candidates);

    if (paths.len == 0) {
        try targeting.collectRecursiveZigFiles(allocator, io, ".", .{}, &candidates);
    } else {
        try collectFormatPaths(allocator, io, paths, &candidates);
    }

    var report: Report = .{ .total_files = candidates.items.len };
    if (candidates.items.len == 0) return report;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "zig");
    try argv.append(allocator, "fmt");
    try argv.append(allocator, "--check");
    for (candidates.items) |path| {
        try argv.append(allocator, path);
    }

    const run_result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stderr_limit = .limited(8 * 1024 * 1024),
        .stdout_limit = .limited(1024 * 1024),
    }) catch |err| {
        report.error_message = try std.fmt.allocPrint(allocator, "failed to run zig fmt: {}", .{err});
        return report;
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    const exit_code: u8 = switch (run_result.term) {
        .exited => |code| code,
        else => {
            report.error_message = try allocator.dupe(u8, "zig fmt terminated unexpectedly");
            return report;
        },
    };
    if (exit_code == 0) return report;

    var failed: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (failed.items) |path| allocator.free(path);
        failed.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, run_result.stderr, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try failed.append(allocator, try allocator.dupe(u8, trimmed));
    }

    report.failed_files = try failed.toOwnedSlice(allocator);
    return report;
}

pub fn percentage(report: Report) f64 {
    if (report.total_files == 0) return 100.0;
    const passed = report.total_files - report.failed_files.len;
    return @as(f64, @floatFromInt(passed)) * 100.0 / @as(f64, @floatFromInt(report.total_files));
}
