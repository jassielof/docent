//! Shared helpers for per-rule option resolution.

const scanning = @import("../scanning.zig");
const Config = @import("../schemas/Config.zig");

/// Returns the effective scan mode for a rule, inheriting the category default when unset.
pub fn resolveScanMode(category_scan: scanning.Modes, override: ?scanning.Modes) scanning.Modes {
    return override orelse category_scan;
}

/// Resolves scan mode from a simple rule config entry.
pub fn scanModeFromSimple(category_scan: scanning.Modes, rule: Config.RuleSimple) scanning.Modes {
    return resolveScanMode(category_scan, rule.scan_mode);
}

/// Resolves scan mode from a threshold rule config entry.
pub fn scanModeFromThreshold(category_scan: scanning.Modes, rule: Config.RuleThreshold) scanning.Modes {
    return resolveScanMode(category_scan, rule.scan_mode);
}

/// Resolves scan mode from a missing-doc-comment rule config entry.
pub fn scanModeFromMissingDocComment(category_scan: scanning.Modes, rule: Config.MissingDocCommentRule) scanning.Modes {
    return resolveScanMode(category_scan, rule.scan_mode);
}

/// Resolves scan mode from an invalid-leading-phrase rule config entry.
pub fn scanModeFromInvalidLeadingPhrase(category_scan: scanning.Modes, rule: Config.InvalidLeadingPhraseRule) scanning.Modes {
    return resolveScanMode(category_scan, rule.scan_mode);
}
