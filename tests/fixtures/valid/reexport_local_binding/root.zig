//! Re-exports a symbol through a local `@import` alias.

pub const helpers = @import("helpers.zig");
pub const greet = helpers.greet;
