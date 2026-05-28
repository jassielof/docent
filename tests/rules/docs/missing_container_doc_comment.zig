//! `missing_container_doc_comment` — library entry roots need a `//!` module doc.

const std = @import("std");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const loc: harness.RuleLocator = .{ .namespace = "docs", .rule_id = "missing_container_doc_comment" };

test "invalid missing_module_doc reports library entry point" {
    var result = try harness.lintRuleFixture(loc, &.{ "invalid", "missing_module_doc", "root.zig" }, .{
        .missing_container_doc_comment = .warn,
    });
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_container_doc_comment", 1);

    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_container_doc_comment")) {
            try std.testing.expect(std.mem.indexOf(u8, d.message, "library entry point") != null);
            try std.testing.expect(std.mem.indexOf(u8, d.message, "root.zig") != null);
        }
    }
}
