/// Documented
pub const hello = "world";

/// Documented container; members below intentionally lack docs (invalid case).
pub const PublicStruct = struct {
    step: i32,
    color: []const u8,

    fn hello() void {}
    pub fn world() void {}
};
