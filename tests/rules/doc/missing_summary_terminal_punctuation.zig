//! `missing_summary_terminal_punctuation` — the summary paragraph must end with `.`, `!`, or `?`.

const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "doc";

test "missing_terminal_punctuation_is_reported" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_summary_terminal_punctuation", "root.zig" }, .{
        .missing_summary_terminal_punctuation = .warn,
    }, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_summary_terminal_punctuation", 1);
}

test "terminal_punctuation_is_accepted" {
    var result = try harness.lintRuleFixture(ns, &.{ "summary_terminal_punctuation_ok", "root.zig" }, .{
        .missing_summary_terminal_punctuation = .warn,
    }, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_summary_terminal_punctuation");
}
