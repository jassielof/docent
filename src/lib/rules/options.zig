//! Shared helpers for per-rule option resolution.

const scanning = @import("../scanning.zig");

/// Returns the effective scan mode for a rule, inheriting the category default when unset.
pub fn resolveScanMode(category_scan: scanning.Modes, override: ?scanning.Modes) scanning.Modes {
    return override orelse category_scan;
}

/// Resolves scan mode from any rule `Config` entry that exposes an optional `scan_mode` field.
pub fn scanModeFromRule(category_scan: scanning.Modes, rule: anytype) scanning.Modes {
    return resolveScanMode(category_scan, rule.scan_mode);
}
