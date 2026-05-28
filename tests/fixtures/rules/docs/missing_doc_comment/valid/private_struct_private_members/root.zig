/// Documented
pub const hello = "world";

// Since the struct is private, omit everything about it, including its members and functions even public ones.
const PrivateStruct = struct {
    step: i32,
    color: []const u8,

    fn hello() void {}
    pub fn world() void {}
};

/// Documented
pub const PublicStruct = struct {
    /// Documented
    step: i32,
    /// Documented
    color: []const u8,

    fn hello() void {}
    /// Documented
    pub fn world() void {}
};
