//! `missing_doctest` — public functions should include runnable doctests when enabled.

const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const loc: harness.RuleLocator = .{ .namespace = "docs", .rule_id = "missing_doctest" };

test "invalid missing_doctests reports one warning" {
    var result = try harness.lintRuleFixture(loc, &.{ "invalid", "missing_doctests", "main.zig" }, .{
        .missing_doc_comment = .allow,
        .missing_doctest = .warn,
    });
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doctest", 1);
}
