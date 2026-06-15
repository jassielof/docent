//! `cognitive_complexity` — functions should stay below the configured cognitive complexity threshold.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "complexity";
const warn = docent.RuleSeverities{ .cognitive_complexity = .warn };

fn configureThreshold6(cfg: *docent.rules.complexity.Complexity) void {
    cfg.cognitive_complexity.options.threshold = 6;
}

fn configureThreshold5(cfg: *docent.rules.complexity.Complexity) void {
    cfg.cognitive_complexity.options.threshold = 5;
}

fn configureThreshold1PublicApi(cfg: *docent.rules.complexity.Complexity) void {
    cfg.cognitive_complexity.options.threshold = 1;
    cfg.cognitive_complexity.scan_mode = .public_api_surface;
}

test "emits a diagnostic only above the threshold" {
    var below = try harness.lintComplexityRuleFixture(ns, &.{ "cognitive_nested_ifs.zig" }, warn, null, configureThreshold6);
    defer below.deinit();
    try utils.expectRuleAbsent(below, "cognitive_complexity");

    var above = try harness.lintComplexityRuleFixture(ns, &.{ "cognitive_nested_ifs.zig" }, warn, null, configureThreshold5);
    defer above.deinit();
    try utils.expectRuleCount(above, "cognitive_complexity", 1);
    try std.testing.expectEqualStrings("complex", above.diagnostics.items[0].subject.?.name);
}

test "private functions are skipped under public_api_only" {
    var result = try harness.lintComplexityRuleFixture(ns, &.{ "cognitive_private_nested_ifs.zig" }, warn, null, configureThreshold1PublicApi);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "cognitive_complexity");
}
