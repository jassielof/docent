//! Assuming this is the library entry point, this tests that the linter shold correctly check for the public reachable symbols of it, and not simply all the public ones.

pub const Vision = @import("Vision.zig");
