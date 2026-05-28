//! `empty_doc_comment` — doc comments must contain non-whitespace text.

const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const loc: harness.RuleLocator = .{ .namespace = "docs", .rule_id = "empty_doc_comment" };

test "valid non_empty ignores partially empty multiline docs" {
    var result = try harness.lintRuleFixture(loc, &.{ "valid", "non_empty", "root.zig" }, .{
        .empty_doc_comment = .warn,
    });
    defer result.deinit();
    try utils.expectRuleAbsent(result, "empty_doc_comment");
}

test "invalid empty_doc_comment_multiline reports fully empty docs" {
    var result = try harness.lintRuleFixture(loc, &.{ "invalid", "empty_doc_comment_multiline", "root.zig" }, .{
        .empty_doc_comment = .warn,
    });
    defer result.deinit();
    try utils.expectRuleCount(result, "empty_doc_comment", 1);
}
