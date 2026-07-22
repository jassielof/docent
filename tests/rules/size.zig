//! Test suite aggregator for size rules.

const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@import("size/max_fun_params.zig"));
    refAllDecls(@import("size/line_length_limit.zig"));
}
