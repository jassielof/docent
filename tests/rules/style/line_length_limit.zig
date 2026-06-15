//! `line_length_limit` — physical lines should stay within the configured maximum width.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "style";
const warn = docent.RuleSeverities{ .line_length_limit = .warn };

test "accepts lines within the limit" {
    var result = try harness.lintStyleRuleFixtureOptions(ns, &.{ "line_length_within_limit.zig" }, warn, .public_api_surface, null, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "line_length_limit");
}

test "warns when a line exceeds max_length" {
    var result = try harness.lintStyleRuleFixtureOptions(ns, &.{ "line_length_exceeds_max.zig" }, warn, .public_api_surface, null, .{ .max_length = 10 });
    defer result.deinit();
    try utils.expectRuleCount(result, "line_length_limit", 1);
    try std.testing.expectEqual(@as(usize, 11), result.diagnostics.items[0].column);
}

test "ignore_trailing_comments excludes trailing // text" {
    var with_comments = try harness.lintStyleRuleFixtureOptions(ns, &.{ "line_length_trailing_comment.zig" }, warn, .public_api_surface, null, .{ .max_length = 20 });
    defer with_comments.deinit();
    try utils.expectRuleCount(with_comments, "line_length_limit", 1);

    var ignored = try harness.lintStyleRuleFixtureOptions(ns, &.{ "line_length_trailing_comment.zig" }, warn, .public_api_surface, null, .{ .max_length = 20, .ignore_trailing_comments = true });
    defer ignored.deinit();
    try utils.expectRuleAbsent(ignored, "line_length_limit");
}

test "ignore_trailing_comments keeps // inside string literals" {
    var result = try harness.lintStyleRuleFixtureOptions(ns, &.{ "line_length_comment_in_string.zig" }, warn, .public_api_surface, null, .{ .max_length = 20, .ignore_trailing_comments = true });
    defer result.deinit();
    try utils.expectRuleCount(result, "line_length_limit", 1);
}

test "ignore_leading_comments excludes doc and line comments" {
    var result = try harness.lintStyleRuleFixtureOptions(ns, &.{ "line_length_leading_comments.zig" }, warn, .public_api_surface, null, .{ .max_length = 20, .ignore_leading_comments = true });
    defer result.deinit();
    try utils.expectRuleAbsent(result, "line_length_limit");
}

test "ignore_leading_comments still measures code lines" {
    var ignored = try harness.lintStyleRuleFixtureOptions(ns, &.{ "line_length_leading_comment_with_code.zig" }, warn, .public_api_surface, null, .{ .max_length = 20, .ignore_leading_comments = true });
    defer ignored.deinit();
    try utils.expectRuleAbsent(ignored, "line_length_limit");

    var measured = try harness.lintStyleRuleFixtureOptions(ns, &.{ "line_length_leading_comment_with_code.zig" }, warn, .public_api_surface, null, .{ .max_length = 20, .ignore_leading_comments = false });
    defer measured.deinit();
    try utils.expectRuleCount(measured, "line_length_limit", 1);
}
