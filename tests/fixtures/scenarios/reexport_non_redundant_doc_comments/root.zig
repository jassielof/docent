//! Test re-export with doc comments on undocumented imported declarations.

/// This belongs in helpers.zig.
const local_helpers = @import("helpers.zig");

/// This belongs in helpers.zig.
pub const helpers = @import("helpers.zig");

/// This belongs on greet in helpers.zig.
pub const greet = helpers.greet;
