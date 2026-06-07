//! How declarations are selected when linting from a module root.
//!
//! These modes match the scanning modes documented in the project README:
//!
//! * `public_api_surface` — only publicly reachable declarations from a module root.
//! * `reachability_traversal` — every declaration in the import closure reachable from a module root.
const std = @import("std");

/// One way to choose which declarations a category of rules inspects.
pub const Mode = enum {
    /// Only `pub` declarations on the publicly reachable API surface.
    public_api_surface,
    /// All declarations in files reachable from the module root (including non-public items).
    reachability_traversal,

    /// Returns whether rule checks should skip non-public declarations.
    pub fn publicApiOnly(self: Mode) bool {
        return self == .public_api_surface;
    }

    /// Parses a `[category] scan_mode` config value.
    pub fn fromConfigString(text: []const u8) ?Mode {
        if (std.mem.eql(u8, text, "public")) return .public_api_surface;
        if (std.mem.eql(u8, text, "all")) return .reachability_traversal;
        return null;
    }

    /// Returns the TOML `scan_mode` string for this mode.
    pub fn configString(self: Mode) []const u8 {
        return switch (self) {
            .public_api_surface => "public",
            .reachability_traversal => "all",
        };
    }
};
