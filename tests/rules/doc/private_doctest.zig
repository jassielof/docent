//! `private_doctest` — doctests should reference public symbols.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "doc";
const warn = harness.isolatedDocRule("private_doctest", .warn);

test "detects doctest referencing private fn, names the symbol" {
    var result = try harness.lintRuleFixture(ns, &.{ "private_doctest_private_fn.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "private_doctest", 1);
    try std.testing.expectEqualStrings("foo", result.diagnostics.items[0].subject.?.name);
}

test "no diagnostic when doctest references pub fn" {
    var result = try harness.lintRuleFixture(ns, &.{ "private_doctest_pub_fn_ok.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "private_doctest");
}

test "no diagnostic for string-literal test names" {
    var result = try harness.lintRuleFixture(ns, &.{ "private_doctest_string_literal_ok.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "private_doctest");
}
