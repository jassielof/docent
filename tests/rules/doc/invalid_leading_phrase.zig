//! `invalid_leading_phrase` — summaries must begin with a valid phrase naming the documented identifier.

const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "doc";

test "summary_without_identifier_is_reported" {
    var result = try harness.lintRuleFixture(ns, &.{ "invalid_leading_phrase", "root.zig" }, .{
        .invalid_leading_phrase = .warn,
    }, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "invalid_leading_phrase", 1);
}

test "summary_with_leading_identifier_is_accepted" {
    var result = try harness.lintRuleFixture(ns, &.{ "leading_phrase_ok", "root.zig" }, .{
        .invalid_leading_phrase = .warn,
    }, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}
