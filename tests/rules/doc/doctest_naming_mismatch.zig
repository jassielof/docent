//! `doctest_naming_mismatch` — doctest names should match declaration identifiers.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "doc";
const warn = harness.isolatedDocRule("doctest_naming_mismatch", .warn);

test "detects string test name matching pub fn, shows correction" {
    var result = try harness.lintRuleFixture(ns, &.{ "doctest_naming_string_match.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "doctest_naming_mismatch", 1);
    try std.testing.expectEqualStrings("foo", result.diagnostics.items[0].subject.?.name);
}

test "no diagnostic for identifier test name" {
    var result = try harness.lintRuleFixture(ns, &.{ "doctest_naming_identifier_ok.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "doctest_naming_mismatch");
}

test "no diagnostic for string test not matching any pub fn" {
    var result = try harness.lintRuleFixture(ns, &.{ "doctest_naming_no_match.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "doctest_naming_mismatch");
}
