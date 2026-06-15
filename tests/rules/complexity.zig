//! Test suite aggregator for complexity rules.

const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@import("complexity/cyclomatic.zig"));
    refAllDecls(@import("complexity/cognitive.zig"));
    refAllDecls(@import("complexity/max_fun_params.zig"));
}
