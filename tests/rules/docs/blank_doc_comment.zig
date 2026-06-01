//! `blank_doc_comment` — doc comments must contain non-whitespace text.

const std = @import("std");
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

test "whole-module re-export resolves blank namespace doc on imported file" {
    const path = try harness.ruleProjectRootPath(ns, "reexport_blank_whole_namespace");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{ .blank_doc_comment = .warn }, .{}, &.{}, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "blank_doc_comment", 1);
    try std.testing.expectEqual(.namespace, result.diagnostics.items[0].subject.?.kind);
    try std.testing.expect(std.mem.endsWith(u8, result.diagnostics.items[0].file, "enums.zig"));
}

test "member-only re-export does not require module doc on imported file" {
    const path = try harness.ruleProjectRootPath(ns, "reexport_member_only_no_module_doc");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{
        .missing_doc_comment = .deny,
        .blank_doc_comment = .warn,
    }, .{}, &.{}, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
    try utils.expectRuleAbsent(result, "blank_doc_comment");
}
