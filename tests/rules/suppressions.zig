//! Integration tests for docent:ignore / docent:disable pragmas.

const std = @import("std");
const docent = @import("docent");

test "docent:ignore-next suppresses identifier_case on following declaration" {
    var style_options = docent.rules.style.Options.defaults();
    style_options.applyRunScanMode(.reachability_traversal);
    var result = try docent.lintStyleSource(
        std.testing.allocator,
        std.testing.io,
        \\// docent:ignore-next identifier_case
        \\pub fn Bad_Name() void {}
        ,
        .{},
        "<test>",
        style_options,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "forbid severity ignores suppression pragmas" {
    var style_options = docent.rules.style.Options.defaults();
    style_options.applyRunScanMode(.reachability_traversal);
    var result = try docent.lintStyleSource(
        std.testing.allocator,
        std.testing.io,
        \\// docent:ignore identifier_case
        \\pub fn Bad_Name() void {}
        ,
        .{ .identifier_case = .forbid },
        "<test>",
        style_options,
    );
    defer result.deinit();
    try std.testing.expect(result.diagnostics.items.len > 0);
}
