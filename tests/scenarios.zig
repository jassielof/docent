//! Scenarios are integration tests that don't focus strictly on a single rule, but rather cover cases where multiple rules interact, complementing the rule-specific tests.

const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@import("scenarios/multi_rule_violations.zig"));
    refAllDecls(@import("scenarios/compliant_all_rules.zig"));
    refAllDecls(@import("scenarios/severity_policy.zig"));
    refAllDecls(@import("scenarios/reach.zig"));
    refAllDecls(@import("scenarios/target.zig"));
    refAllDecls(@import("scenarios/manifest_and_config.zig"));
    refAllDecls(@import("scenarios/config_presets.zig"));
    refAllDecls(@import("scenarios/doc_reexport.zig"));
    refAllDecls(@import("scenarios/identifier_case_imports.zig"));
}
