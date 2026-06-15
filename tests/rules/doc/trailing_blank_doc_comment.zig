//! `trailing_blank_doc_comment` — doc comments must not end with blank lines.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "doc";
const warn = harness.isolatedDocRule("trailing_blank_doc_comment", .warn);

test "detects trailing blank /// line" {
    var result = try harness.lintRuleFixture(ns, &.{ "trailing_blank_doc_comment.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "trailing_blank_doc_comment", 1);
    try std.testing.expectEqual(.function, result.diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("add", result.diagnostics.items[0].subject.?.name);
}

test "detects multiple trailing blank /// lines once" {
    var result = try harness.lintRuleFixture(ns, &.{ "trailing_blank_multiple_lines.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "trailing_blank_doc_comment", 1);
    try std.testing.expectEqual(@as(usize, 2), result.diagnostics.items[0].line);
}

test "no diagnostic for internal blank lines" {
    var result = try harness.lintRuleFixture(ns, &.{ "partially_empty_doc_comment.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "trailing_blank_doc_comment");
}

test "no diagnostic when block ends with content" {
    var result = try harness.lintRuleFixture(ns, &.{ "trailing_blank_content_end_ok.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "trailing_blank_doc_comment");
}

test "no diagnostic for fully blank block" {
    var result = try harness.lintRuleFixture(ns, &.{ "trailing_blank_fully_blank_ok.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "trailing_blank_doc_comment");
}

test "detects trailing blank on //! module doc" {
    var result = try harness.lintRuleFixtureDisplay(ns, &.{ "trailing_blank_module_doc.zig" }, warn, .{}, "root.zig");
    defer result.deinit();
    try utils.expectRuleCount(result, "trailing_blank_doc_comment", 1);
    try std.testing.expectEqual(.module, result.diagnostics.items[0].subject.?.kind);
}

test "detects trailing blank /// on enum enumerator" {
    var result = try harness.lintRuleFixture(ns, &.{ "trailing_blank_enum_enumerator.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "trailing_blank_doc_comment", 1);
    try std.testing.expectEqual(.enumerator, result.diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("red", result.diagnostics.items[0].subject.?.name);
}
