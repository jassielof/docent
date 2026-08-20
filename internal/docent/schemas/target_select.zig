//! Filesystem selection settings shared by check commands.
//! Per-category `scan_mode` (`public` / `all`) still controls visibility
//! inside the reachable graph after targets are selected.

const std = @import("std");

/// Filesystem paths for `docent check`.
pub const Check = struct {
    include: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    /// Whether configured includes extend the package paths from `build.zig.zon`.
    inherit_manifest: bool = true,

    pub fn deinit(self: *Check, allocator: std.mem.Allocator) void {
        freePathList(allocator, self.include);
        freePathList(allocator, self.exclude);
        self.include = &.{};
        self.exclude = &.{};
    }
};

fn freePathList(allocator: std.mem.Allocator, list: []const []const u8) void {
    if (list.len == 0) return;
    for (list) |path| allocator.free(path);
    allocator.free(list);
}
