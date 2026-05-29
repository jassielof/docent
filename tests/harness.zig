//! Fixture path helpers. Rule/scenario test files pass their namespace and id explicitly.

const std = @import("std");
const builtin = @import("builtin");
const docent = @import("docent");

const is_windows = builtin.os.tag == .windows;

pub const RuleLocator = struct {
    namespace: []const u8,
    rule_id: []const u8,

    pub fn fixturePath(self: RuleLocator, allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
        const rules_root = try std.fs.path.join(allocator, &.{ "tests", "fixtures", "rules" });
        defer allocator.free(rules_root);

        var list: [16][]const u8 = undefined;
        var n: usize = 0;
        list[n] = rules_root;
        n += 1;
        list[n] = self.namespace;
        n += 1;
        list[n] = self.rule_id;
        n += 1;
        for (parts) |p| {
            list[n] = p;
            n += 1;
        }
        return std.fs.path.join(allocator, list[0..n]);
    }
};

pub const ScenarioLocator = struct {
    name: []const u8,

    pub fn fixturePath(self: ScenarioLocator, allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
        const scenarios_root = try std.fs.path.join(allocator, &.{ "tests", "fixtures", "scenarios", self.name });
        defer allocator.free(scenarios_root);

        var list: [16][]const u8 = undefined;
        var n: usize = 0;
        list[n] = scenarios_root;
        n += 1;
        for (parts) |p| {
            list[n] = p;
            n += 1;
        }
        return std.fs.path.join(allocator, list[0..n]);
    }
};

pub fn readFixtureFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]const u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(std.math.maxInt(u32)),
        .of(u8),
        0,
    );
}

pub fn lintFixturePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rule_set: docent.RuleSet,
    display_path: []const u8,
) !docent.LintResult {
    const source = try readFixtureFile(allocator, io, path);
    defer allocator.free(source);
    return docent.lintSource(allocator, io, source, rule_set, display_path, .{}, &.{});
}

pub fn lintRuleFixture(
    locator: RuleLocator,
    parts: []const []const u8,
    rule_set: docent.RuleSet,
) !docent.LintResult {
    const allocator = std.testing.allocator;
    const path = try locator.fixturePath(allocator, parts);
    defer allocator.free(path);
    const display = try relativeFixtureDisplay(allocator, path);
    defer allocator.free(display);
    return lintFixturePath(allocator, std.testing.io, path, rule_set, display);
}

pub fn ruleProjectRootPath(locator: RuleLocator, kind: []const u8, case_name: []const u8) ![]const u8 {
    const allocator = std.testing.allocator;
    return locator.fixturePath(allocator, &.{ "project", kind, case_name, "root.zig" });
}

pub fn lintScenarioFixture(
    locator: ScenarioLocator,
    parts: []const []const u8,
    rule_set: docent.RuleSet,
) !docent.LintResult {
    const allocator = std.testing.allocator;
    const path = try locator.fixturePath(allocator, parts);
    defer allocator.free(path);
    const display = try relativeFixtureDisplay(allocator, path);
    defer allocator.free(display);
    return lintFixturePath(allocator, std.testing.io, path, rule_set, display);
}

pub fn scenarioProjectPath(locator: ScenarioLocator, rel: []const u8) ![]const u8 {
    const allocator = std.testing.allocator;
    return locator.fixturePath(allocator, &.{rel});
}

pub fn relativeFixtureDisplay(allocator: std.mem.Allocator, absolute: []const u8) ![]const u8 {
    const tests_idx = std.mem.indexOf(u8, absolute, if (is_windows) "\\tests\\" else "/tests/") orelse
        std.mem.indexOf(u8, absolute, "tests/") orelse
        std.mem.indexOf(u8, absolute, "tests\\") orelse
        return allocator.dupe(u8, absolute);
    const offset = if (std.mem.indexOf(u8, absolute, "tests/")) |_| "tests/".len else "tests\\".len;
    return allocator.dupe(u8, absolute[tests_idx + offset ..]);
}
