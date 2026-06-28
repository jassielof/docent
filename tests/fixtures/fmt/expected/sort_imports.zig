//! Module doc comment stays at the top.

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Target = std.Target;

pub fn main() void {
    const x: Allocator = undefined;
    _ = x;
    const t: Target = undefined;
    _ = t;
    _ = builtin.os;
}
