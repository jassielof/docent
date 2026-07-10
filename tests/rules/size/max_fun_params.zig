//! `max_fun_params` — functions should stay within the configured parameter count limit.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "size";
const warn = docent.RuleSeverities{ .max_fun_params = .warn };

fn configureThreshold7(cfg: *docent.rules.size.Size) void {
    cfg.max_function_parameters.options.threshold = 7;
}

fn configureThreshold7PublicApi(cfg: *docent.rules.size.Size) void {
    cfg.max_function_parameters.options.threshold = 7;
    cfg.max_function_parameters.scan_mode = .public_api_surface;
}

test "function within threshold is accepted" {
    var result = try harness.lintSizeRuleFixture(ns, &.{ "max_fun_params_within_threshold.zig" }, warn, null, configureThreshold7);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "max_fun_params");
}

test "function above threshold is reported" {
    var result = try harness.lintSizeRuleFixture(ns, &.{ "max_fun_params_above_threshold.zig" }, warn, null, configureThreshold7);
    defer result.deinit();
    try utils.expectRuleCount(result, "max_fun_params", 1);
    try std.testing.expectEqualStrings("too_many", result.diagnostics.items[0].subject.?.name);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostics.items[0].detail.?, "8 parameters") != null);
}

test "exactly at threshold is accepted" {
    var result = try harness.lintSizeRuleFixture(ns, &.{ "max_fun_params_at_threshold.zig" }, warn, null, configureThreshold7);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "max_fun_params");
}

test "private functions are measured when public_api_only is false" {
    var result = try harness.lintSizeRuleFixture(ns, &.{ "max_fun_params_private_above.zig" }, warn, null, configureThreshold7);
    defer result.deinit();
    try utils.expectRuleCount(result, "max_fun_params", 1);
}

test "private functions are skipped under public_api_only" {
    var result = try harness.lintSizeRuleFixture(ns, &.{ "max_fun_params_private_above.zig" }, warn, null, configureThreshold7PublicApi);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "max_fun_params");
}
