//! `cyclomatic_complexity` — functions should stay below the configured cyclomatic complexity threshold.

const std = @import("std");
const docent = @import("docent");
const utils = @import("../../utils.zig");

fn lint(source: [:0]const u8, threshold: u32) !docent.LintResult {
    return docent.lintComplexitySource(
        std.testing.allocator,
        source,
        .{ .cyclomatic_complexity = .warn },
        "<test>",
        .{ .scan_mode = .reachability_traversal },
        .{ .cyclomatic_threshold = threshold },
    );
}

test "public function above threshold is reported" {
    var result = try lint(
        \\pub fn complex(x: i32) i32 {
        \\    if (x == 1) {
        \\        return 1;
        \\    } else if (x == 2) {
        \\        return 2;
        \\    } else {
        \\        return 3;
        \\    }
        \\}
    , 2);
    defer result.deinit();
    try utils.expectRuleCount(result, "cyclomatic_complexity", 1);
}

test "simple function below threshold is accepted" {
    var result = try lint(
        \\pub fn simple(x: u32) u32 {
        \\    return x + 1;
        \\}
    , 10);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "cyclomatic_complexity");
}

test "non-public functions are also measured" {
    var result = try lint(
        \\fn complex(x: i32) i32 {
        \\    if (x == 1) {
        \\        return 1;
        \\    } else if (x == 2) {
        \\        return 2;
        \\    } else {
        \\        return 3;
        \\    }
        \\}
    , 2);
    defer result.deinit();
    try utils.expectRuleCount(result, "cyclomatic_complexity", 1);
}

test "default threshold leaves simple declarations clean" {
    var result = try docent.lintComplexitySource(
        std.testing.allocator,
        \\fn helper(x: u32) u32 {
        \\    return x + 1;
        \\}
    ,
        .{ .cyclomatic_complexity = .warn },
        "<test>",
        .{ .scan_mode = .reachability_traversal },
        .{},
    );
    defer result.deinit();
    try utils.expectRuleAbsent(result, "cyclomatic_complexity");
}

test "switch with many prongs exceeds default threshold" {
    var result = try docent.lintComplexitySource(
        std.testing.allocator,
        \\pub fn classify(n: u8) []const u8 {
        \\    switch (n) {
        \\        0 => return "zero",
        \\        1 => return "one",
        \\        2 => return "two",
        \\        3 => return "three",
        \\        4 => return "four",
        \\        5 => return "five",
        \\        6 => return "six",
        \\        7 => return "seven",
        \\        8 => return "eight",
        \\        9 => return "nine",
        \\        else => return "many",
        \\    }
        \\}
    ,
        .{ .cyclomatic_complexity = .warn },
        "<test>",
        .{ .scan_mode = .reachability_traversal },
        .{ .cyclomatic_threshold = 10 },
    );
    defer result.deinit();
    try utils.expectRuleCount(result, "cyclomatic_complexity", 1);
}
