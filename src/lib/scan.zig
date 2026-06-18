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

// TODO: Rename modes, as the documentation explains it. While it mainly mentions 2, the first one (reachability) has 2 flavors (public API only vs. including internal declarations).
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
