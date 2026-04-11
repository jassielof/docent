/// The severity level of a lint rule.
pub const Level = enum {
    /// doc
    allow,
    /// doc
    deny,
    /// doc
    warn,
    /// doc
    forbid,

    /// Returns true when the severity is not `.allow`.
    pub fn isActive(self: Level) bool {
        return self != .allow;
    }
};

pub const EvenDeeper = @import("deeper.zig").Deepest;
