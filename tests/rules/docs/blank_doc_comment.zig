//! `blank_doc_comment` — doc comments must contain non-whitespace text.

const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "docs";

test "partially_empty_doc_comment ignores blank lines in multiline docs" {
    var result = try harness.lintRuleFixture(ns, &.{ "partially_empty_doc_comment", "root.zig" }, .{
        .blank_doc_comment = .warn,
    }, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "blank_doc_comment");
}

test "fully_blank_multiline_doc_comment reports fully blank docs" {
    var result = try harness.lintRuleFixture(ns, &.{ "fully_blank_multiline_doc_comment", "root.zig" }, .{
        .blank_doc_comment = .warn,
    }, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "blank_doc_comment", 1);
}
