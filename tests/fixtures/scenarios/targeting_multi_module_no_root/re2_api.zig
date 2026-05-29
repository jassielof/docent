//! Re2 API definitions.

/// Public Re2 type.
pub const Re2 = struct {
    //! Re2 container docs.

    const hidden = @import("internal/private_only.zig");

    /// Compiles a pattern.
    pub fn compile(_: []const u8) void {
        hidden.helper();
    }

    test compile {}
};
