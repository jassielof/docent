//! Re-export project scenarios for doc rules that genuinely resolve a second file on disk.
//!
//! Most re-export/alias behavior in the doc rules (`missing_doc_comment`, `misplaced_doc_comment`)
//! is pure AST pattern matching on the importing file alone — no file is ever opened to check the
//! imported declaration's own documentation, so those cases are covered as single-file inline
//! tests in their respective `lib/rules/doc/*.zig` files instead. `blank_doc_comment` is the one
//! rule that actually reads the imported file, to resolve whether a re-exported whole module's own
//! `//!` block is blank — that real cross-file behavior is what belongs here.

const std = @import("std");
const testing = std.testing;

const docent = @import("docent");

const harness = @import("../harness.zig");
const utils = @import("../utils.zig");

test "whole-module re-export resolves blank namespace doc on imported file" {
    const path = try harness.scenarioProjectRootPath("reexport_blank_whole_namespace");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(
        std.testing.allocator,
        std.testing.io,
        path,
        .{},
        &.{},
        harness.docConfig(.{ .blank_doc_comment = .warn }),
    );
    defer result.deinit();
    try utils.expectRuleCount(
        result,
        "blank_doc_comment",
        1,
    );
    try testing.expectEqual(.namespace, result.diagnostics.items[0].subject.?.kind);
    try testing.expect(std.mem.endsWith(
        u8,
        result.diagnostics.items[0].file,
        "enums.zig",
    ));
}
