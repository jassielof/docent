//! Represents a diagnostic issue or warning generated during static analysis.

const Severity = @import("Severity.zig");

/// Byte range within `message` for emphasized rendering in TTY output.
pub const EmphasisSpan = struct {
    ///// Start byte offset within `message`.
    offset: usize,
    /// Length in bytes of the emphasized span.
    len: usize,
};

/// The identifier of the lint rule that triggered this diagnostic.
rule: []const u8,
/// The severity level of the diagnostic.
severity: Severity.Level,
/// A detailed message explaining the issue.
message: []const u8,
/// When set, TTY formatters render this byte range of `message` with emphasis (italic when supported).
emphasis: ?EmphasisSpan = null,
/// The path to the file where the diagnostic was found.
file: []const u8,
/// The 1-based line number in the source file where the diagnostic occurs.
line: usize,
/// The 1-based column number in the source file where the diagnostic occurs.
column: usize,
/// The trimmed source line where the diagnostic occurs. Empty if unavailable.
source_line: []const u8 = "",
/// Length of the highlighted token for the ^~~~ span. Defaults to 1.
symbol_len: usize = 1,
