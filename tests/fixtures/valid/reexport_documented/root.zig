//! A library that re-exports a documented symbol.

// No doc comment on the re-export line intentionally — the doc comment lives
// in severity.zig on the original declaration and must be resolved there.
pub const Severity = @import("severity.zig").Level;
// TODO: This is to test if it can resolve multiple levels of re-exports.
pub const Deeper = @import("severity.zig").EvenDeeper;
