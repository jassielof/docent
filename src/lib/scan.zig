//! The scan namespace offers utilities for scanning and analyzing Zig modules.
//!
//! Zig modules are assumed to have a module root, such as the conventional `src/root.zig` for a library, or `src/main.zig` for an executable. The module root is the entry point for scanning and linting.
//!
//! Traversal operates under a `RuleScanConfig` composed of:
//!
//! - **ScanMode:**
//!   - `reachability`: traversal starts strictly from the module root and walks reachable declarations only.
//!   - `filesystem`: recursive walk over every `.zig` file on disk, including orphaned files.
//!
//! - **Visibility:** (only applicable to `.reachability`)
//!   - `public_only`: inspects only publicly visible (`pub`) declarations.
//!   - `include_internal`: extends the walk past `pub` boundaries to collect non-public (internal) declarations.

const std = @import("std");

pub const ScanMode = enum {
    reachability,
    filesystem,
};

pub const Visibility = enum {
    public_only,
    include_internal,

    pub fn isPublicOnly(self: Visibility) bool {
        return self == .public_only;
    }
};

pub const RuleScanConfig = struct {
    mode: ScanMode,
    visibility: Visibility,

    pub const public_api_surface = RuleScanConfig{
        .mode = .reachability,
        .visibility = .public_only,
    };
    pub const reachability_traversal = RuleScanConfig{
        .mode = .reachability,
        .visibility = .include_internal,
    };
    pub const filesystem = RuleScanConfig{
        .mode = .filesystem,
        .visibility = .include_internal,
    };

    pub fn publicApiOnly(self: RuleScanConfig) bool {
        return self.visibility.isPublicOnly();
    }

    pub fn fromConfigString(text: []const u8) ?RuleScanConfig {
        if (std.mem.eql(u8, text, "public")) return public_api_surface;
        if (std.mem.eql(u8, text, "all")) return reachability_traversal;
        if (std.mem.eql(u8, text, "filesystem")) return filesystem;
        return null;
    }

    pub fn configString(self: RuleScanConfig) []const u8 {
        if (self.mode == .filesystem) return "filesystem";
        return switch (self.visibility) {
            .public_only => "public",
            .include_internal => "all",
        };
    }
};

pub const target = @import("scan/target.zig");
pub const reach = @import("scan/reach.zig");
pub const alias = @import("scan/alias.zig");
