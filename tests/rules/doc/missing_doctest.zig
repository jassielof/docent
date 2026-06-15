//! `missing_doctest` — public functions should include runnable doctests when enabled.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "doc";
const warn = harness.isolatedDocRule("missing_doctest", .warn);

test "detects missing doctest for pub fn, names the function" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doctest_pub_fn.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doctest", 1);
    try std.testing.expectEqualStrings("foo", result.diagnostics.items[0].subject.?.name);
}

test "no diagnostic when doctest exists" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doctest_with_test_ok.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doctest");
}

test "no diagnostic for private fn" {
    var result = try harness.lintRuleFixture(ns, &.{ "missing_doctest_private_ok.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doctest");
}
