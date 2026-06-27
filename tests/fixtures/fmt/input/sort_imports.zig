//! Module doc comment stays at the top.

const std = @import("std");
const vereda = @import("vereda");

const suppressions = @import("suppressions.zig");

const Ast = std.zig.Ast;

const carnaval = @import("carnaval");
pub const Diagnostic = @import("Diagnostic.zig");
pub const config = @import("config.zig");
pub const Suppressions = suppressions.Table;
const root = @import("root");
const builtin = @import("builtin");

pub fn main() void {
    const x = foo();
    return x;
}
