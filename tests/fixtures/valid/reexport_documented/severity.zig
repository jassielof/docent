/// The severity level of a lint rule.
pub const Level = enum {
    allow,
    warn,
    deny,
    forbid,

    /// Returns true when the severity is not `.allow`.
    pub fn isActive(self: Level) bool {
        return self != .allow;
    }
};
