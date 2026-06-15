//! A library that re-exports an undocumented symbol.

// No doc comment on the re-export; none on the original either — should
// produce exactly one diagnostic pointing to severity.zig, not root.zig.
pub const Severity = @import("severity.zig").Level;
