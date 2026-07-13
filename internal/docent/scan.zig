//! The scan namespace offers utilities for scanning and analyzing Zig modules.
//!
//! Docent has two product-level scan models:
//!
//! - **Module API (check / typeset):** starts strictly from a module root
//!   declared in `build.zig` (`root_source_file`), then runs reachability
//!   analysis over the import/declaration graph. Orphan `.zig` files that are
//!   never reached from a module root are ignored.
//! - **Filesystem (fmt):** recursive directory walk over every `.zig` / `.zon`
//!   file on disk, including orphans. Path `include` / `exclude` live under
//!   `[fmt]` in `.config/docent.toml`.
//!
//! Traversal for check rules operates under a `RuleScanConfig` composed of:
//!
//! - **ScanMode:**
//!   - `reachability`: module-root reachability (the check/typeset model).
//!   - `filesystem`: recursive walk including orphans (available for explicit
//!     opt-in / multi-path CLI escape hatches; not what TOML `scan_mode`
//!     `"public"` / `"all"` select).
//!
//! - **Visibility:** (only applicable to `.reachability`)
//!   - `public_only`: inspects only publicly visible (`pub`) declarations.
//!   - `include_internal`: extends past `pub` boundaries to collect internal
//!     declarations in already-reachable files.
//!
//! TOML `scan_mode = "public"` maps to `public_api_surface`; `"all"` maps to
//! `reachability_traversal`. Both stay on the module-API graph.

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
