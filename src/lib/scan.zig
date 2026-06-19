//! The scan namespace offers utilities for scanning and analyzing Zig modules.
//!
//! Zig modules are assumed to have a module root, such as the conventional `src/root.zig` for a library, or `src/main.zig` for an executable. The module root is the entry point for scanning and linting, it'll do a reachability traversal to find all symbols in the module.
//!
//! There are 2 main scanning modes:
//!
//! - **Reachability scan:** starts strictly from the module root and walks every declaration reachable from it, following explicit re-export aliases (`pub const Foo = other.Foo;`) along the way. By default only `pub` declarations are collected, producing the public API surface. Passing `include_internal` extends the walk past `pub` boundaries to also collect non-public (internal) declarations, yielding the full declaration set reachable from the root.
//!
//! - **Filesystem scan:** ignores reachability entirely and recursively walks every `.zig` file under a given directory, the same way a formatter would. This also picks up orphaned files — files present on disk that are never `@import`ed from the module root, and would therefore be invisible to a reachability scan. This mode is used for format-style checks, where every file on disk matters regardless of whether the module root ever references it.

const std = @import("std");

// TODO(refactor): Split `Modes` into `ScanMode` + `Visibility` — current flat enum conflates
// discovery strategy with visibility filtering, which will break down once filesystem scan is added.
//
// Target shape:
//
//   ScanMode = enum { reachability, filesystem }
//     - `reachability`: traversal from module root, following reachable declarations only.
//     - `filesystem`: recursive walk over every .zig file on disk, including orphaned files.
//
//   Visibility = enum { public_only, include_internal }
//     - Only meaningful when paired with `.reachability`.
//     - Filesystem scans always inspect all declarations; pub/internal has no bearing on
//       whether a file gets walked, so this field is N/A for `.filesystem`.
//
//   RuleScanConfig = struct { mode: ScanMode, visibility: Visibility }
//     - Flat config string ("public", "all", "filesystem") parsed into both fields at once,
//       preserving current TOML surface for users.
//     - "public"   -> .{ .reachability, .public_only }
//     - "all"      -> .{ .reachability, .include_internal }
//     - "filesystem" -> .{ .filesystem, .include_internal }
//
// Migration:
//   - Replace all `Modes` references with `RuleScanConfig` or the individual types as appropriate.
//   - `publicApiOnly()` moves to `Visibility.isPublicOnly()`.
//   - `fromConfigString` / `configString` move to `RuleScanConfig`.
//   - Update doc comments on the `scan` namespace to reflect 2 modes + visibility as a filter.

/// One way to choose which declarations a category of rules inspects.
pub const Modes = enum {
    /// Only `pub` declarations on the publicly reachable API surface.
    public_api_surface,
    /// All declarations in files reachable from the module root (including non-public items).
    reachability_traversal,

    /// Returns whether rule checks should skip non-public declarations.
    pub fn publicApiOnly(self: Modes) bool {
        return self == .public_api_surface;
    }

    /// Parses a `[category] scan_mode` config value.
    pub fn fromConfigString(text: []const u8) ?Modes {
        if (std.mem.eql(u8, text, "public")) return .public_api_surface;
        if (std.mem.eql(u8, text, "all")) return .reachability_traversal;
        return null;
    }

    /// Returns the TOML `scan_mode` string for this mode.
    pub fn configString(self: Modes) []const u8 {
        return switch (self) {
            .public_api_surface => "public",
            .reachability_traversal => "all",
        };
    }
};

pub const target = @import("scan/target.zig");
pub const reach = @import("scan/reach.zig");
pub const alias = @import("scan/alias.zig");
