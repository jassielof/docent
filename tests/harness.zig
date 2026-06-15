//! Harness helps with fixture path utilities for flat rule and scenario layouts under `tests/fixtures/`.
//!
//! - `fixtures/rules/<namespace>/<case_id>.zig` — single-file rule cases.
//! - `fixtures/rules/<namespace>/<case_id>/` — project fixtures (`root.zig` entry, optional extra sources).
//! - `fixtures/scenarios/<case_id>.zig` — single-file scenario cases.
//! - `fixtures/scenarios/<case_id>/` — scenario project trees.
//!
//! To add a rule test:
//! 1. Add `fixtures/rules/<namespace>/<case_id>.zig`, or a directory `fixtures/rules/<namespace>/<case_id>/` with `root.zig`.
//! 2. Add or extend `rules/<namespace>/<rule_id>.zig` and call `harness.lintRuleFixture("<namespace>", &.{ ... }, rule_set, .{})`.
//! 3. Import the test file from `rules/<namespace>.zig`.

const std = @import("std");
const builtin = @import("builtin");
const docent = @import("docent");

const is_windows = builtin.os.tag == .windows;

/// Resolves `tests/fixtures/rules/<namespace>/…`.
pub fn ruleFixturePath(allocator: std.mem.Allocator, namespace: []const u8, parts: []const []const u8) ![]const u8 {
    const rules_root = try std.fs.path.join(allocator, &.{ "tests", "fixtures", "rules", namespace });
    defer allocator.free(rules_root);

    var list: [16][]const u8 = undefined;
    var n: usize = 0;
    list[n] = rules_root;
    n += 1;
    for (parts) |p| {
        list[n] = p;
        n += 1;
    }
    return std.fs.path.join(allocator, list[0..n]);
}

/// Resolves `tests/fixtures/scenarios/…`.
pub fn scenarioFixturePath(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    const scenarios_root = try std.fs.path.join(allocator, &.{ "tests", "fixtures", "scenarios" });
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
    rule_set: docent.RuleSeverities,
    display_path: []const u8,
    options: docent.LintOptions,
) !docent.LintResult {
    const source = try readFixtureFile(allocator, io, path);
    defer allocator.free(source);
    var doc_cfg = docent.rules.doc.Doc.defaults();
    applyDocSeverities(&doc_cfg, rule_set);
    return docent.lintSource(allocator, io, source, display_path, options, &.{}, doc_cfg);
}

/// Builds a doc config with severities projected from `rule_set` (other settings at defaults).
pub fn docConfig(rule_set: docent.RuleSeverities) docent.rules.doc.Doc {
    var cfg = docent.rules.doc.Doc.defaults();
    applyDocSeverities(&cfg, rule_set);
    return cfg;
}

/// Projects the doc severities from a `RuleSeverities` onto a doc config for fixture linting.
fn applyDocSeverities(cfg: *docent.rules.doc.Doc, rule_set: docent.RuleSeverities) void {
    cfg.missing_doc_comment.level = rule_set.missing_doc_comment;
    cfg.blank_doc_comment.level = rule_set.blank_doc_comment;
    cfg.trailing_blank_doc_comment.level = rule_set.trailing_blank_doc_comment;
    cfg.missing_summary_terminal_punctuation.level = rule_set.missing_summary_terminal_punctuation;
    cfg.missing_doctest.level = rule_set.missing_doctest;
    cfg.private_doctest.level = rule_set.private_doctest;
    cfg.doctest_naming_mismatch.level = rule_set.doctest_naming_mismatch;
    cfg.invalid_leading_phrase.level = rule_set.invalid_leading_phrase;
}

pub fn lintRuleFixture(
    namespace: []const u8,
    parts: []const []const u8,
    rule_set: docent.RuleSeverities,
    options: docent.LintOptions,
) !docent.LintResult {
    const allocator = std.testing.allocator;
    const path = try ruleFixturePath(allocator, namespace, parts);
    defer allocator.free(path);
    const display = try relativeFixtureDisplay(allocator, path);
    defer allocator.free(display);
    return lintFixturePath(allocator, std.testing.io, path, rule_set, display, options);
}

/// `tests/fixtures/rules/<namespace>/<case_dir>/root.zig` for project fixtures.
pub fn ruleProjectRootPath(namespace: []const u8, case_dir: []const u8) ![]const u8 {
    const allocator = std.testing.allocator;
    return ruleFixturePath(allocator, namespace, &.{ case_dir, "root.zig" });
}

pub fn lintScenarioFixture(
    parts: []const []const u8,
    rule_set: docent.RuleSeverities,
    options: docent.LintOptions,
) !docent.LintResult {
    const allocator = std.testing.allocator;
    const path = try scenarioFixturePath(allocator, parts);
    defer allocator.free(path);
    const display = try relativeFixtureDisplay(allocator, path);
    defer allocator.free(display);
    return lintFixturePath(allocator, std.testing.io, path, rule_set, display, options);
}

/// Directory path for a scenario project fixture (`tests/fixtures/scenarios/<case_dir>`).
pub fn scenarioProjectDir(case_dir: []const u8) ![]const u8 {
    const allocator = std.testing.allocator;
    return scenarioFixturePath(allocator, &.{case_dir});
}

/// File path inside a scenario project fixture.
pub fn scenarioProjectPath(case_dir: []const u8, rel: []const u8) ![]const u8 {
    const allocator = std.testing.allocator;
    return scenarioFixturePath(allocator, &.{ case_dir, rel });
}

pub fn relativeFixtureDisplay(allocator: std.mem.Allocator, absolute: []const u8) ![]const u8 {
    const tests_idx = std.mem.indexOf(u8, absolute, if (is_windows) "\\tests\\" else "/tests/") orelse
        std.mem.indexOf(u8, absolute, "tests/") orelse
        std.mem.indexOf(u8, absolute, "tests\\") orelse
        return allocator.dupe(u8, absolute);
    const offset = if (std.mem.indexOf(u8, absolute, "tests/")) |_| "tests/".len else "tests\\".len;
    return allocator.dupe(u8, absolute[tests_idx + offset ..]);
}
