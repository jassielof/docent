//! `trailing_blank_doc_comment` — doc comments must not end with blank lines.

const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "docs";

test "internal_blank_lines_in_multiline_doc_are_allowed" {
    var result = try harness.lintRuleFixture(ns, &.{ "partially_empty_doc_comment", "root.zig" }, .{
        .trailing_blank_doc_comment = .warn,
    }, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "trailing_blank_doc_comment");
}

test "trailing_blank_line_after_doc_text_is_reported" {
    var result = try harness.lintRuleFixture(ns, &.{ "trailing_blank_doc_comment", "root.zig" }, .{
        .trailing_blank_doc_comment = .warn,
    }, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "trailing_blank_doc_comment", 1);
}
