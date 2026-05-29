//! Scenario: one fixture exercises several documentation rules together.

const docent = @import("docent");
const harness = @import("../harness.zig");
const utils = @import("../utils.zig");

test "multi_rule_doc_violations triggers multiple rule ids" {
    var result = try harness.lintScenarioFixture(&.{"multi_rule_doc_violations.zig"}, .{
        .missing_doc_comment = .warn,
        .blank_doc_comment = .warn,
        .private_doctest = .warn,
        .doctest_naming_mismatch = .warn,
    }, .{});
    defer result.deinit();
    try utils.expectHasRules(result, &.{
        "missing_doc_comment",
        "blank_doc_comment",
        "private_doctest",
        "doctest_naming_mismatch",
    });
}
