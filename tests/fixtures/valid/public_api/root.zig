//! Assuming this is the library entry point, this tests that the linter shold correctly check for the public reachable symbols of it, and not simply all the public ones.

/// My vision struct
pub const Vision = @import("vision.zig");

