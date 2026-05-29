//! Public API surface.

/// Exported API namespace.
pub const API = struct {
    //! API type exports.

    /// Main data model.
    pub const Model = @import("model.zig").Model;

    /// Extra helper namespace.
    pub const Extra = @import("extra.zig");

    // Private import must not be considered part of the reachable public API.
    const hidden = @import("private_only.zig");

    test API {}
};
