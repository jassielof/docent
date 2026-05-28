//! Test suite aggregator — import test modules here only; no test logic in this file.

const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@import("rules/docs.zig"));
    refAllDecls(@import("rules/complexity.zig"));
    refAllDecls(@import("rules/style.zig"));
    refAllDecls(@import("scenarios.zig"));
}
