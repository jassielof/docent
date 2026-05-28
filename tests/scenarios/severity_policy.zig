//! Scenario: severity levels and process exit policy (not tied to a single rule fixture).

const std = @import("std");
const docent = @import("docent");
const cli = @import("cli");
const fangz = @import("fangz");
const harness = @import("../harness.zig");

const mixed_loc: harness.ScenarioLocator = .{ .name = "multi_rule_violations" };

test "allow suppresses all diagnostics on mixed fixture" {
    var result = try harness.lintScenarioFixture(mixed_loc, &.{ "invalid", "mixed", "main.zig" }, .{
        .missing_doc_comment = .allow,
        .empty_doc_comment = .allow,
        .private_doctest = .allow,
        .doctest_naming_mismatch = .allow,
        .missing_container_doc_comment = .allow,
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "warnings alone do not fail the process summary" {
    var summary: docent.output.Summary = .{ .warnings = 3 };
    try std.testing.expect(!summary.hasErrors());
    summary.errors = 1;
    try std.testing.expect(summary.hasErrors());
}

test "rule_config forbid cannot be relaxed" {
    var rs: docent.RuleSet = .{};
    rs.missing_doc_comment = .forbid;

    const pair = fangz.KeyValuePair{ .key = "missing_doc_comment", .value = "warn" };
    try cli.rule_config.applyRuleOverride(&rs, pair);
    try std.testing.expect(rs.missing_doc_comment == .forbid);
}
