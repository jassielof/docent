//! `cyclomatic_complexity` — functions should stay below the configured cyclomatic complexity threshold.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "complexity";
const warn = docent.RuleSeverities{ .cyclomatic_complexity = .warn };

fn configureThreshold3(cfg: *docent.rules.complexity.Complexity) void {
    cfg.cyclomatic_complexity.options.threshold = 3;
}

fn configureThreshold2(cfg: *docent.rules.complexity.Complexity) void {
    cfg.cyclomatic_complexity.options.threshold = 2;
}

fn configureThreshold1PublicApi(cfg: *docent.rules.complexity.Complexity) void {
    cfg.cyclomatic_complexity.options.threshold = 1;
    cfg.cyclomatic_complexity.scan_mode = .public_api_surface;
}

test "emits a diagnostic only above the threshold" {
    var at = try harness.lintComplexityRuleFixture(ns, &.{ "cyclomatic_complex_if_chain.zig" }, warn, null, configureThreshold3);
    defer at.deinit();
    try utils.expectRuleAbsent(at, "cyclomatic_complexity");

    var above = try harness.lintComplexityRuleFixture(ns, &.{ "cyclomatic_complex_if_chain.zig" }, warn, null, configureThreshold2);
    defer above.deinit();
    try utils.expectRuleCount(above, "cyclomatic_complexity", 1);
    try std.testing.expectEqualStrings("complex", above.diagnostics.items[0].subject.?.name);
}

test "private functions are skipped under public_api_only" {
    var result = try harness.lintComplexityRuleFixture(ns, &.{ "cyclomatic_private_if_chain.zig" }, warn, null, configureThreshold1PublicApi);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "cyclomatic_complexity");
}
