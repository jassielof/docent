//! `cognitive_complexity` — functions should stay below the configured cognitive complexity threshold.

const std = @import("std");
const docent = @import("docent");
const utils = @import("../../utils.zig");

fn lint(source: [:0]const u8, threshold: u32) !docent.LintResult {
    var cfg = docent.rules.complexity.Complexity.defaults();
    cfg.cognitive_complexity.options.threshold = threshold;
    return docent.lintComplexitySource(std.testing.allocator, source, "<test>", cfg);
}

test "public function above threshold is reported" {
    var result = try lint(
        \\pub fn complex(a: bool, b: bool, c: bool) void {
        \\    if (a) {
        \\        if (b) {
        \\            if (c) {}
        \\        }
        \\    }
        \\}
    , 5);
    defer result.deinit();
    try utils.expectRuleCount(result, "cognitive_complexity", 1);
}

test "simple function below threshold is accepted" {
    var result = try lint(
        \\pub fn simple(x: u32) u32 {
        \\    return x + 1;
        \\}
    , 15);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "cognitive_complexity");
}

test "non-public functions are also measured" {
    var result = try lint(
        \\fn complex(a: bool, b: bool, c: bool) void {
        \\    if (a) {
        \\        if (b) {
        \\            if (c) {}
        \\        }
        \\    }
        \\}
    , 5);
    defer result.deinit();
    try utils.expectRuleCount(result, "cognitive_complexity", 1);
}

test "default threshold leaves simple declarations clean" {
    var result = try docent.lintComplexitySource(
        std.testing.allocator,
        \\fn helper(x: u32) u32 {
        \\    return x + 1;
        \\}
    ,
        "<test>",
        docent.rules.complexity.Complexity.defaults(),
    );
    defer result.deinit();
    try utils.expectRuleAbsent(result, "cognitive_complexity");
}
