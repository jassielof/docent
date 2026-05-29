// TODO: tests/rules/style/<rule_id>.zig — loc_column_length, …
const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@import("style/identifier_case.zig"));
}
