//! `missing_doctest` — public functions should include runnable doctests when enabled.

const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "docs";

test "pub_fn_missing_doctest reports one warning" {
    var result = try harness.lintRuleFixture(ns, &.{"pub_fn_missing_doctest.zig"}, .{
        .missing_doc_comment = .allow,
        .missing_doctest = .warn,
    }, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doctest", 1);
}
