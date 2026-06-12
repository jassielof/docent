//! `max_fun_params` — functions should stay within the configured parameter count limit.

const std = @import("std");
const docent = @import("docent");
const utils = @import("../../utils.zig");

fn lint(source: [:0]const u8, threshold: u32) !docent.LintResult {
    var cfg = docent.rules.complexity.Complexity.defaults();
    cfg.max_function_parameters.options.threshold = threshold;
    return docent.lintComplexitySource(std.testing.allocator, source, "<test>", cfg);
}

test "function above default threshold is reported" {
    var result = try lint(
        \\pub fn too_many(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32) void {}
    , 7);
    defer result.deinit();
    try utils.expectRuleCount(result, "max_fun_params", 1);
}

test "function at threshold is accepted" {
    var result = try lint(
        \\pub fn seven(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32) void {}
    , 7);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "max_fun_params");
}

test "non-public functions are also measured" {
    var result = try lint(
        \\fn hidden(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32) void {}
    , 7);
    defer result.deinit();
    try utils.expectRuleCount(result, "max_fun_params", 1);
}

test "default threshold leaves small signatures clean" {
    var result = try docent.lintComplexitySource(
        std.testing.allocator,
        \\fn helper(allocator: std.mem.Allocator, io: std.Io) void {}
    ,
        "<test>",
        docent.rules.complexity.Complexity.defaults(),
    );
    defer result.deinit();
    try utils.expectRuleAbsent(result, "max_fun_params");
}
