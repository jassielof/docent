//! Severity levels for lint rules and diagnostics.
//!
//! All rules accept one of the levels from `Level`.
//!
//! The distinction between _Deny_ and _Forbid_ matter for locking a rule in CI regardless of any local flag overrides. For example, setting _Forbid_ in the manifest cannot be weakened to any other level in the command line.

/// Effective level of a rule or diagnostic.
pub const Level = enum {
    /// Rule is disabled; no diagnostics are emitted.
    allow,
    /// Report issues without failing the process (unless fail-fast is enabled).
    /// Diagnostics are emitted, but they do not cause the process to exit with an error code.
    warn,
    /// Report issues and cause a non-zero exit when any diagnostic is present.
    /// Diagnostics are emitted, and the process exits with an error code.
    deny,
    /// Like "deny", but cannot be relaxed by later `--rule` overrides.
    /// Similar to "deny", but the rule cannot be overriden by a subsequent configuration.
    forbid,

    /// Returns whether this level can produce diagnostics.
    pub fn isActive(self: Level) bool {
        return self != .allow;
    }

    /// Returns whether this level should fail the lint run (exit code / build step).
    pub fn isError(self: Level) bool {
        return self == .deny or self == .forbid;
    }
};
