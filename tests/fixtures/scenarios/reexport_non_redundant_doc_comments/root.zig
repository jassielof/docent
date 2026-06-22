//! Test re-export with non-redundant doc comments.

/// No target container doc comment, so this is NOT redundant
pub const helpers = @import("helpers.zig");

/// Target is undocumented, so this is NOT redundant
pub const greet = helpers.greet;
