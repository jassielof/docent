//! Test re-export with redundant doc comments.

/// Redundant doc comment for whole-module
pub const helpers = @import("helpers.zig");

/// Redundant doc comment for member
pub const greet = helpers.greet;
