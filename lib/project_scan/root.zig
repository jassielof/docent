//! Discovers filesystem paths a project-wide `docent` CLI operation should operate over.

const std = @import("std");

pub const target = @import("target.zig");

comptime {
    std.testing.refAllDecls(@This());
}
