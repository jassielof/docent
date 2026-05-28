//! Test suite aggregator — import test modules here only; no test logic in this file.

const std = @import("std");
const testing = std.testing;

comptime {
    testing.refAllDecls(@This());
    testing.refAllDecls(@import("harness.zig"));

    // Rule tests (filesystem registry: tests/rules/<namespace>/<rule>.zig)
    testing.refAllDecls(@import("rules/docs/missing_doc_comment.zig"));
    testing.refAllDecls(@import("rules/docs/missing_doctest.zig"));
    testing.refAllDecls(@import("rules/docs/empty_doc_comment.zig"));
    testing.refAllDecls(@import("rules/docs/missing_container_doc_comment.zig"));

    // TODO: tests/rules/complexity/<rule_id>.zig — cyclomatic, cognitive, max_fun_params, …
    // TODO: tests/rules/style/<rule_id>.zig — identifier_case, loc_column_length, …

    // Scenario tests (complementary multi-rule / integration cases)
    testing.refAllDecls(@import("scenarios/multi_rule_violations.zig"));
    testing.refAllDecls(@import("scenarios/compliant_all_rules.zig"));
    testing.refAllDecls(@import("scenarios/severity_policy.zig"));
    testing.refAllDecls(@import("scenarios/reachability.zig"));
    testing.refAllDecls(@import("scenarios/targeting.zig"));
    testing.refAllDecls(@import("scenarios/manifest_and_config.zig"));
}
