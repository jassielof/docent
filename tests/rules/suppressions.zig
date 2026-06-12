//! Integration tests for docent:ignore / docent:disable pragmas.

const std = @import("std");
const docent = @import("docent");

test "docent:ignore-next suppresses identifier_case on following declaration" {
    var style_cfg = docent.rules.style.Style.defaults();
    style_cfg.applyRunScanMode(.reachability_traversal);
    var result = try docent.lintStyleSource(
        std.testing.allocator,
        std.testing.io,
        \\// docent:ignore-next identifier_case
        \\pub fn Bad_Name() void {}
        ,
        "<test>",
        style_cfg,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "forbid severity ignores suppression pragmas" {
    var style_cfg = docent.rules.style.Style.defaults();
    style_cfg.applyRunScanMode(.reachability_traversal);
    style_cfg.identifier_case.level = .forbid;
    var result = try docent.lintStyleSource(
        std.testing.allocator,
        std.testing.io,
        \\// docent:ignore identifier_case
        \\pub fn Bad_Name() void {}
        ,
        "<test>",
        style_cfg,
    );
    defer result.deinit();
    try std.testing.expect(result.diagnostics.items.len > 0);
}
