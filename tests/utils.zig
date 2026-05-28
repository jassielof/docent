//! Shared assertions for lint test results.

const std = @import("std");
const docent = @import("docent");

pub fn countRule(result: docent.LintResult, rule_name: []const u8) usize {
    var n: usize = 0;
    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, rule_name)) n += 1;
    }
    return n;
}

pub fn expectRuleCount(result: docent.LintResult, rule_name: []const u8, expected: usize) !void {
    try std.testing.expectEqual(expected, countRule(result, rule_name));
}

pub fn expectRuleAbsent(result: docent.LintResult, rule_name: []const u8) !void {
    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, rule_name)) return error.UnexpectedDiagnostic;
    }
}

pub fn expectRulePresent(result: docent.LintResult, rule_name: []const u8) !void {
    if (countRule(result, rule_name) == 0) return error.TestExpectedEqual;
}

pub fn expectHasRules(result: docent.LintResult, rules: []const []const u8) !void {
    for (rules) |name| try expectRulePresent(result, name);
}
