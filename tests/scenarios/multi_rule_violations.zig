//! Scenario: one fixture exercises several documentation rules together.

const docent = @import("docent");
const harness = @import("../harness.zig");
const utils = @import("../utils.zig");

const loc: harness.ScenarioLocator = .{ .name = "multi_rule_violations" };

test "invalid mixed fixture triggers multiple rule ids" {
    var result = try harness.lintScenarioFixture(loc, &.{ "invalid", "mixed", "main.zig" }, .{
        .missing_doc_comment = .warn,
        .empty_doc_comment = .warn,
        .private_doctest = .warn,
        .doctest_naming_mismatch = .warn,
        .missing_container_doc_comment = .warn,
    });
    defer result.deinit();
    try utils.expectHasRules(result, &.{
        "missing_doc_comment",
        "empty_doc_comment",
        "private_doctest",
        "doctest_naming_mismatch",
    });
}
