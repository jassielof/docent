//! `missing_summary_terminal_punctuation` — the summary paragraph must end with `.`, `!`, or `?`.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "doc";
const warn = harness.isolatedDocRule("missing_summary_terminal_punctuation", .warn);

test "detects missing terminal punctuation on /// comment" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_summary_terminal_punctuation.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_summary_terminal_punctuation", 1);
    try std.testing.expectEqualStrings("add", result.diagnostics.items[0].subject.?.name);
}

test "well-punctuated summary is clean" {
    var result = try harness.lintRuleFixture(ns, &.{ "summary_terminal_punctuation_ok.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_summary_terminal_punctuation");
}

test "accepts exclamation and question marks" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_summary_exclamation_question_ok.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_summary_terminal_punctuation");
}

test "only first paragraph is checked" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_summary_second_paragraph_ok.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_summary_terminal_punctuation");
}

test "multiline summary within first paragraph" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_summary_multiline_no_punct.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_summary_terminal_punctuation", 1);
}

test "multiline summary with punctuation is clean" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_summary_multiline_ok.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_summary_terminal_punctuation");
}

test "blank doc comment is skipped" {
    var result = try harness.lintRuleFixture(ns, &.{ "blank_doc_empty_line.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_summary_terminal_punctuation");
}

test "detects missing punctuation on //! module doc" {
    var result = try harness.lintRuleFixtureDisplay(ns, &.{ "missing_summary_module_no_punct.zig" }, warn, .{}, "root.zig");
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_summary_terminal_punctuation", 1);
    try std.testing.expectEqual(.module, result.diagnostics.items[0].subject.?.kind);
}

test "enum member summary punctuation" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_summary_enum_enumerator.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_summary_terminal_punctuation", 1);
    try std.testing.expectEqual(.enumerator, result.diagnostics.items[0].subject.?.kind);
}
