//! Scenario: fully compliant fixture with strict severities on all documentation rules.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../harness.zig");

const loc: harness.ScenarioLocator = .{ .name = "compliant_all_rules" };

test "valid compliant fixture passes with all doc rules enabled" {
    var result = try harness.lintScenarioFixture(loc, &.{ "valid", "compliant", "main.zig" }, .{
        .missing_doc_comment = .deny,
        .empty_doc_comment = .deny,
        .missing_doctest = .warn,
        .missing_container_doc_comment = .deny,
    });
    defer result.deinit();
    try std.testing.expect(!result.hasErrors());
}
