//! Discovers which files and build targets a project-wide operation (the `docent` CLI, `typeset`)
//! should operate over: `build.zig` target/step parsing, CLI target-selection filtering, and
//! import-graph reachability from a module root.
//!
//! Distinct from `rules.scan` (`RuleScanConfig`), which controls how a single already-selected
//! file is scanned by one rule (public-API-only vs. every reachable declaration), not which files
//! get selected in the first place.

const std = @import("std");

pub const build_scan = @import("build_scan.zig");
pub const target = @import("target.zig");
pub const reach = @import("reach.zig");

comptime {
    std.testing.refAllDecls(@This());
}
