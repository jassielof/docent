//! Severity levels for lint rules and diagnostics.

/// Effective level of a rule or diagnostic.
pub const Level = enum {
    /// Rule is disabled; no diagnostics are emitted.
    allow,
    /// Report issues without failing the process (unless fail-fast is enabled).
    warn,
    /// Report issues and cause a non-zero exit when any diagnostic is present.
    deny,
    /// Like `deny`, but cannot be relaxed by later `--rule` overrides.
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
