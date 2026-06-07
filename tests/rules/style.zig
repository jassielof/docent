//! Test suite aggregator for style rules.

const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@import("style/identifier_case.zig"));
    refAllDecls(@import("style/line_length_limit.zig"));
}
