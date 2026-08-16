//! Scan settings shared by check commands.
//!
//! These configure *which* `build.zig` module roots participate. They do not
//! switch Docent to a filesystem orphan walk — that remains `fmt`'s model.
//! Per-category `scan_mode` (`public` / `all`) still controls visibility
//! inside the reachable graph after targets are selected.

const std = @import("std");

/// Filesystem paths for `docent check`.
pub const Check = struct {
    include: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},

    pub fn deinit(self: *Check, allocator: std.mem.Allocator) void {
        freePathList(allocator, self.include);
        freePathList(allocator, self.exclude);
        self.include = &.{};
        self.exclude = &.{};
    }
};

/// Typeset discovery + emission defaults (same module-root model as check).
pub const Typeset = struct {
    lib: bool = false,
    bins: bool = false,
    tests: bool = false,
    deps: bool = false,
    include_private: bool = false,
    bundle_std: bool = false,
    /// Default docs.json path. Owned when non-default from TOML; free with `deinit`.
    output: []const u8 = "docs.json",
    exclude_targets: []const []const u8 = &.{},
    output_owned: bool = false,

    pub fn deinit(self: *Typeset, allocator: std.mem.Allocator) void {
        freePathList(allocator, self.exclude_targets);
        self.exclude_targets = &.{};
        if (self.output_owned) {
            allocator.free(self.output);
            self.output = "docs.json";
            self.output_owned = false;
        }
    }
};

fn freePathList(allocator: std.mem.Allocator, list: []const []const u8) void {
    if (list.len == 0) return;
    for (list) |path| allocator.free(path);
    allocator.free(list);
}
