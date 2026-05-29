//! Example vision struct
const utils = @import("utils.zig");

const Self = @This();

/// My eyesight
eyesight: []const u8,
/// My favorite color
color: []const u8,

/// See the world
pub fn see(_: Self) void {
    utils.lookingYou();
}
