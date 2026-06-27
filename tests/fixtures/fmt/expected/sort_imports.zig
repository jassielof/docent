//! Module doc comment stays at the top.

const builtin = @import("builtin");
const std = @import("std");
const Ast = std.zig.Ast;

const carnaval = @import("carnaval");
const vereda = @import("vereda");

pub const config = @import("config.zig");
pub const Diagnostic = @import("Diagnostic.zig");
const root = @import("root");
const suppressions = @import("suppressions.zig");
pub const Suppressions = suppressions.Table;

pub fn main() void {
    const x = foo();
    return x;
}
