const Severity = @This();

/// The severity level of a lint rule.
pub const Level = enum {
    allow,
    warn,
    deny,
    forbid,

    pub fn isActive(self: Level) bool {
        return self != .allow;
    }

    pub fn isError(self: Level) bool {
        return self == .deny or self == .forbid;
    }
};
