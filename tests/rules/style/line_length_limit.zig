//! `line_length_limit` — physical lines should stay within the configured maximum width.

const std = @import("std");
const docent = @import("docent");
const utils = @import("../../utils.zig");

fn lint(source: [:0]const u8, rule_set: docent.RuleSeverities, options: docent.rules.style.line_length_limit.Options) !docent.LintResult {
    var style_options = docent.rules.style.Options.defaults();
    style_options.line_length_limit = options;
    return docent.lintStyleSource(
        std.testing.allocator,
        std.testing.io,
        source,
        rule_set,
        "<test>",
        style_options,
    );
}

test "short lines are accepted" {
    var result = try lint("pub fn ok() void {}\n", .{ .line_length_limit = .warn }, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "line_length_limit");
}

test "long lines are reported" {
    const source =
        \\////1234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890
        \\
    ;
    var result = try lint(source, .{ .line_length_limit = .warn }, .{ .max_length = 10 });
    defer result.deinit();
    try utils.expectRuleCount(result, "line_length_limit", 1);
}

test "ignore_trailing_comments keeps code width only" {
    const source =
        \\pub const x = 1; // aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        \\
    ;
    var result = try lint(
        source,
        .{ .line_length_limit = .warn },
        .{ .max_length = 20, .ignore_trailing_comments = true },
    );
    defer result.deinit();
    try utils.expectRuleAbsent(result, "line_length_limit");
}
