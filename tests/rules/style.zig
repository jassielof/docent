const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@import("style/identifier_case.zig"));
}
