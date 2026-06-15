//! `blank_doc_comment` — doc comments must contain non-whitespace text.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "doc";
const warn = harness.isolatedDocRule("blank_doc_comment", .warn);

test "detects blank /// comment" {
    var result = try harness.lintRuleFixture(ns, &.{ "blank_doc_empty_line.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "blank_doc_comment", 1);
    try std.testing.expectEqual(.function, result.diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("foo", result.diagnostics.items[0].subject.?.name);
    try std.testing.expectEqual(@as(usize, 3), result.diagnostics.items[0].symbol_len);
}

test "detects blank /// on enum enumerator" {
    var result = try harness.lintRuleFixture(ns, &.{ "blank_doc_enum_enumerator.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "blank_doc_comment", 1);
    try std.testing.expectEqual(.enumerator, result.diagnostics.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("red", result.diagnostics.items[0].subject.?.name);
}

test "detects blank /// with spaces" {
    var result = try harness.lintRuleFixture(ns, &.{ "blank_doc_empty_with_spaces.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "blank_doc_comment", 1);
}

test "no diagnostic for non-empty doc comment" {
    var result = try harness.lintRuleFixture(ns, &.{ "blank_doc_nonempty_ok.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "blank_doc_comment");
}

test "detects blank //! comment on module entry" {
    var result = try harness.lintRuleFixtureDisplay(ns, &.{ "blank_doc_module_entry.zig" }, warn, .{}, "root.zig");
    defer result.deinit();
    try utils.expectRuleCount(result, "blank_doc_comment", 1);
    try std.testing.expectEqual(.module, result.diagnostics.items[0].subject.?.kind);
}

test "blank //! on non-entry file uses namespace subject" {
    var result = try harness.lintRuleFixture(ns, &.{ "blank_doc_namespace_blank.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "blank_doc_comment", 1);
    try std.testing.expectEqual(.namespace, result.diagnostics.items[0].subject.?.kind);
}

test "detects fully blank multiline /// comment block once" {
    var result = try harness.lintRuleFixture(ns, &.{ "fully_blank_multiline_doc_comment.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "blank_doc_comment", 1);
}

test "no diagnostic for multiline block with at least one non-empty line" {
    var result = try harness.lintRuleFixture(ns, &.{ "partially_empty_doc_comment.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "blank_doc_comment");
}

test "member re-export does not trigger whole-module blank check" {
    var result = try harness.lintRuleFixture(ns, &.{ "blank_doc_member_reexport_skip.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "blank_doc_comment");
}
