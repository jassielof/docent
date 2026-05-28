const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@import("scenarios/multi_rule_violations.zig"));
    refAllDecls(@import("scenarios/compliant_all_rules.zig"));
    refAllDecls(@import("scenarios/severity_policy.zig"));
    refAllDecls(@import("scenarios/reachability.zig"));
    refAllDecls(@import("scenarios/targeting.zig"));
    refAllDecls(@import("scenarios/manifest_and_config.zig"));
}
