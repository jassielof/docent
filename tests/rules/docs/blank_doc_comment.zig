//! `blank_doc_comment` — doc comments must contain non-whitespace text.

const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const loc: harness.RuleLocator = .{ .namespace = "docs", .rule_id = "blank_doc_comment" };

test "valid non_empty ignores partially empty multiline docs" {
    var result = try harness.lintRuleFixture(loc, &.{ "valid", "non_empty", "root.zig" }, .{
        .blank_doc_comment = .warn,
    });
    defer result.deinit();
    try utils.expectRuleAbsent(result, "blank_doc_comment");
}

test "invalid blank_doc_comment_multiline reports fully blank docs" {
    var result = try harness.lintRuleFixture(loc, &.{ "invalid", "blank_doc_comment_multiline", "root.zig" }, .{
        .blank_doc_comment = .warn,
    });
    defer result.deinit();
    try utils.expectRuleCount(result, "blank_doc_comment", 1);
}
