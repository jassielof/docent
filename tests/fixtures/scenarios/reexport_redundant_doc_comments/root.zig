//! Test re-export with redundant doc comments.

/// Misplaced doc comment for whole-module import
pub const helpers = @import("helpers.zig");

/// Misplaced doc comment for member re-export
pub const greet = helpers.greet;
