// Deliberately no doc comment on Level to trigger the re-export diagnostic.
pub const Level = enum {
    allow,
    warn,
    deny,
    forbid,
};
