//! `cyclomatic_complexity` — functions should stay below the configured cyclomatic complexity threshold.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "complexity";
const warn = docent.RuleSeverities{ .cyclomatic_complexity = .warn };

/// Generates a configuration function for a specific complexity threshold.
fn configureThreshold(comptime threshold: u32) *const fn (*docent.rules.complexity.Complexity) void {
    return struct {
        fn func(cfg: *docent.rules.complexity.Complexity) void {
            cfg.cyclomatic_complexity.options.threshold = threshold;
        }
    }.func;
}

fn configureThreshold1PublicApi(cfg: *docent.rules.complexity.Complexity) void {
    cfg.cyclomatic_complexity.options.threshold = 1;
    cfg.cyclomatic_complexity.scan_mode = .public_api_surface;
}

test "emits a diagnostic only above the threshold (if chain complexity 3)" {
    const expected_score = 3;

    // Threshold = 3 (equal to expected score): should not emit any diagnostic.
    var equal_to_threshold = try harness.lintComplexityRuleFixture(ns, &.{"cyclomatic_complex_if_chain.zig"}, warn, null, configureThreshold(expected_score));
    defer equal_to_threshold.deinit();
    try utils.expectRuleAbsent(equal_to_threshold, "cyclomatic_complexity");

    // Threshold = 2 (less than expected score): should emit exactly 1 diagnostic.
    var above_threshold = try harness.lintComplexityRuleFixture(ns, &.{"cyclomatic_complex_if_chain.zig"}, warn, null, configureThreshold(expected_score - 1));
    defer above_threshold.deinit();
    try utils.expectRuleCount(above_threshold, "cyclomatic_complexity", 1);
    try std.testing.expectEqualStrings("complex", above_threshold.diagnostics.items[0].subject.?.name);
}

test "private functions are skipped under public_api_only" {
    var result = try harness.lintComplexityRuleFixture(ns, &.{"cyclomatic_private_if_chain.zig"}, warn, null, configureThreshold1PublicApi);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "cyclomatic_complexity");
}

test "empty function has a cyclomatic complexity score of exactly 1" {
    const expected_score = 1;

    // Threshold = 1 (equal to expected score): should not emit any diagnostic.
    var equal_to_threshold = try harness.lintComplexityRuleFixture(ns, &.{"cyclomatic_empty_fn.zig"}, warn, null, configureThreshold(expected_score));
    defer equal_to_threshold.deinit();
    try utils.expectRuleAbsent(equal_to_threshold, "cyclomatic_complexity");

    // Threshold = 0 (less than expected score): should emit exactly 1 diagnostic.
    var above_threshold = try harness.lintComplexityRuleFixture(ns, &.{"cyclomatic_empty_fn.zig"}, warn, null, configureThreshold(expected_score - 1));
    defer above_threshold.deinit();
    try utils.expectRuleCount(above_threshold, "cyclomatic_complexity", 1);
}

test "switch counts each prong (except last/default, complexity 4)" {
    const expected_score = 4;

    // Threshold = 4 (equal to expected score): should not emit any diagnostic.
    var equal_to_threshold = try harness.lintComplexityRuleFixture(ns, &.{"cyclomatic_switch.zig"}, warn, null, configureThreshold(expected_score));
    defer equal_to_threshold.deinit();
    try utils.expectRuleAbsent(equal_to_threshold, "cyclomatic_complexity");

    // Threshold = 3 (less than expected score): should emit exactly 1 diagnostic.
    var above_threshold = try harness.lintComplexityRuleFixture(ns, &.{"cyclomatic_switch.zig"}, warn, null, configureThreshold(expected_score - 1));
    defer above_threshold.deinit();
    try utils.expectRuleCount(above_threshold, "cyclomatic_complexity", 1);
}

test "logical operators add decision points (complexity 3)" {
    const expected_score = 3;

    // Threshold = 3 (equal to expected score): should not emit any diagnostic.
    var equal_to_threshold = try harness.lintComplexityRuleFixture(ns, &.{"cyclomatic_logical.zig"}, warn, null, configureThreshold(expected_score));
    defer equal_to_threshold.deinit();
    try utils.expectRuleAbsent(equal_to_threshold, "cyclomatic_complexity");

    // Threshold = 2 (less than expected score): should emit exactly 1 diagnostic.
    var above_threshold = try harness.lintComplexityRuleFixture(ns, &.{"cyclomatic_logical.zig"}, warn, null, configureThreshold(expected_score - 1));
    defer above_threshold.deinit();
    try utils.expectRuleCount(above_threshold, "cyclomatic_complexity", 1);
}

test "catch adds a decision point (complexity 2)" {
    const expected_score = 2;

    // Threshold = 2 (equal to expected score): should not emit any diagnostic.
    var equal_to_threshold = try harness.lintComplexityRuleFixture(ns, &.{"cyclomatic_catch.zig"}, warn, null, configureThreshold(expected_score));
    defer equal_to_threshold.deinit();
    try utils.expectRuleAbsent(equal_to_threshold, "cyclomatic_complexity");

    // Threshold = 1 (less than expected score): should emit exactly 1 diagnostic.
    var above_threshold = try harness.lintComplexityRuleFixture(ns, &.{"cyclomatic_catch.zig"}, warn, null, configureThreshold(expected_score - 1));
    defer above_threshold.deinit();
    try utils.expectRuleCount(above_threshold, "cyclomatic_complexity", 1);
}

test "orelse is ignored (complexity 1)" {
    const expected_score = 1;

    // Threshold = 1 (equal to expected score): should not emit any diagnostic.
    var equal_to_threshold = try harness.lintComplexityRuleFixture(ns, &.{"cyclomatic_orelse.zig"}, warn, null, configureThreshold(expected_score));
    defer equal_to_threshold.deinit();
    try utils.expectRuleAbsent(equal_to_threshold, "cyclomatic_complexity");

    // Threshold = 0 (less than expected score): should emit exactly 1 diagnostic.
    var above_threshold = try harness.lintComplexityRuleFixture(ns, &.{"cyclomatic_orelse.zig"}, warn, null, configureThreshold(expected_score - 1));
    defer above_threshold.deinit();
    try utils.expectRuleCount(above_threshold, "cyclomatic_complexity", 1);
}
