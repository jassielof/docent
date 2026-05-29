//! Scenario: fully compliant fixture with strict severities on all documentation rules.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../harness.zig");

test "all_doc_rules_compliant passes with strict doc rules enabled" {
    var result = try harness.lintScenarioFixture(&.{"all_doc_rules_compliant.zig"}, .{
        .missing_doc_comment = .deny,
        .blank_doc_comment = .deny,
        .missing_doctest = .warn,
    }, .{});
    defer result.deinit();
    try std.testing.expect(!result.hasErrors());
}
