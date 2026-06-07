//! Shared helpers for per-rule option resolution.

const scan_modes = @import("../scan_modes.zig");
const Config = @import("../schemas/Config.zig");

/// Returns the effective scan mode for a rule, inheriting the category default when unset.
pub fn resolveScanMode(category_scan: scan_modes.Mode, override: ?scan_modes.Mode) scan_modes.Mode {
    return override orelse category_scan;
}

/// Resolves scan mode from a simple rule config entry.
pub fn scanModeFromSimple(category_scan: scan_modes.Mode, rule: Config.RuleSimple) scan_modes.Mode {
    return resolveScanMode(category_scan, rule.scan_mode);
}

/// Resolves scan mode from a threshold rule config entry.
pub fn scanModeFromThreshold(category_scan: scan_modes.Mode, rule: Config.RuleThreshold) scan_modes.Mode {
    return resolveScanMode(category_scan, rule.scan_mode);
}

/// Resolves scan mode from a missing-doc-comment rule config entry.
pub fn scanModeFromMissingDocComment(category_scan: scan_modes.Mode, rule: Config.MissingDocCommentRule) scan_modes.Mode {
    return resolveScanMode(category_scan, rule.scan_mode);
}
