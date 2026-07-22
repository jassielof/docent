//! Harness helps with fixture path utilities for flat rule and scenario layouts under `tests/fixtures/`.
//!
//! - `fixtures/rules/<namespace>/<case_id>.zig` — single-file rule cases only.
//! - `fixtures/scenarios/<case_id>.zig` — single-file scenario cases.
//! - `fixtures/scenarios/<case_id>/` — scenario project trees (multi-file, imports, re-exports).
//!
//! To add a rule test:
//! 1. Add `fixtures/rules/<namespace>/<case_id>.zig`.
//! 2. Add or extend `rules/<namespace>/<rule_id>.zig` and call `harness.lintRuleFixture`
//!    (or `expectRuleFixtureTable` for several cases in one test).
//! 3. Import the test file from `rules/<namespace>.zig`.
//!
//! Prefer table-driven cases when many fixtures only differ by expected count:
//!
//! ```zig
//! try harness.expectRuleFixtureTable("doc", &.{
//!     .{ .parts = &.{"compliant.zig"}, .expect_count = 0 },
//!     .{ .parts = &.{"missing.zig"}, .expect_count = 1 },
//! }, rule_set, .{});
//! ```

const std = @import("std");
const builtin = @import("builtin");
const docent = @import("docent");
const utils = @import("utils.zig");

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
    doc_cfg.applyRunScanMode(options.scan_mode);
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
    cfg.redundant_doc_comment.level = rule_set.redundant_doc_comment;
}

/// Returns a `RuleSeverities` with every doc rule at `.allow` except one set to `level`.
pub fn isolatedDocRule(comptime rule: []const u8, level: docent.SeverityLevel) docent.RuleSeverities {
    var rs = docent.RuleSeverities{
        .missing_doc_comment = .allow,
        .missing_doctest = .allow,
        .private_doctest = .allow,
        .blank_doc_comment = .allow,
        .missing_summary_terminal_punctuation = .allow,
        .trailing_blank_doc_comment = .allow,
        .doctest_naming_mismatch = .allow,
        .invalid_leading_phrase = .allow,
        .redundant_doc_comment = .allow,
    };
    @field(rs, rule) = level;
    return rs;
}

pub fn lintRuleFixture(
    namespace: []const u8,
    parts: []const []const u8,
    rule_set: docent.RuleSeverities,
    options: docent.LintOptions,
) !docent.LintResult {
    return lintRuleFixtureDisplay(namespace, parts, rule_set, options, null);
}

pub fn lintRuleFixtureDisplay(
    namespace: []const u8,
    parts: []const []const u8,
    rule_set: docent.RuleSeverities,
    options: docent.LintOptions,
    display_path: ?[]const u8,
) !docent.LintResult {
    const allocator = std.testing.allocator;
    const path = try ruleFixturePath(allocator, namespace, parts);
    defer allocator.free(path);
    const display = if (display_path) |dp| try allocator.dupe(u8, dp) else try relativeFixtureDisplay(allocator, path);
    defer allocator.free(display);
    return lintFixturePath(allocator, std.testing.io, path, rule_set, display, options);
}

pub fn lintRuleFixtureConfigured(
    namespace: []const u8,
    parts: []const []const u8,
    rule_set: docent.RuleSeverities,
    options: docent.LintOptions,
    display_path: ?[]const u8,
    configure: ?*const fn (*docent.rules.doc.Doc) void,
) !docent.LintResult {
    const allocator = std.testing.allocator;
    const path = try ruleFixturePath(allocator, namespace, parts);
    defer allocator.free(path);
    const display = if (display_path) |dp| try allocator.dupe(u8, dp) else try relativeFixtureDisplay(allocator, path);
    defer allocator.free(display);

    const source = try readFixtureFile(allocator, std.testing.io, path);
    defer allocator.free(source);
    var doc_cfg = docConfig(rule_set);
    doc_cfg.applyRunScanMode(options.scan_mode);
    if (configure) |configure_fn| configure_fn(&doc_cfg);
    return docent.lintSource(allocator, std.testing.io, source, display, options, &.{}, doc_cfg);
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

/// `tests/fixtures/scenarios/<case_dir>/root.zig` for scenario project entry points.
pub fn scenarioProjectRootPath(case_dir: []const u8) ![]const u8 {
    const allocator = std.testing.allocator;
    return scenarioFixturePath(allocator, &.{ case_dir, "root.zig" });
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

fn styleConfig(rule_set: docent.RuleSeverities, scan_mode: docent.scan.RuleScanConfig) docent.rules.style.Style {
    var cfg = docent.rules.style.Style.defaults();
    cfg.identifier_case.level = rule_set.identifier_case;
    cfg.applyRunScanMode(scan_mode);
    return cfg;
}

pub fn lintStyleRuleFixture(
    namespace: []const u8,
    parts: []const []const u8,
    rule_set: docent.RuleSeverities,
    scan_mode: docent.scan.RuleScanConfig,
    display_path: ?[]const u8,
    configure: ?*const fn (*docent.rules.style.Style) void,
) !docent.LintResult {
    const allocator = std.testing.allocator;
    const path = try ruleFixturePath(allocator, namespace, parts);
    defer allocator.free(path);
    const display = if (display_path) |dp| try allocator.dupe(u8, dp) else try relativeFixtureDisplay(allocator, path);
    defer allocator.free(display);

    const source = try readFixtureFile(allocator, std.testing.io, path);
    defer allocator.free(source);
    var style_cfg = styleConfig(rule_set, scan_mode);
    if (configure) |configure_fn| configure_fn(&style_cfg);
    return docent.lintStyleSource(allocator, std.testing.io, source, display, style_cfg);
}

pub fn lintSizeRuleFixtureOptions(
    namespace: []const u8,
    parts: []const []const u8,
    rule_set: docent.RuleSeverities,
    scan_mode: docent.scan.RuleScanConfig,
    display_path: ?[]const u8,
    line_length_options: docent.rules.size.line_length_limit.Options,
) !docent.LintResult {
    const allocator = std.testing.allocator;
    const path = try ruleFixturePath(allocator, namespace, parts);
    defer allocator.free(path);
    const display = if (display_path) |dp| try allocator.dupe(u8, dp) else try relativeFixtureDisplay(allocator, path);
    defer allocator.free(display);

    const source = try readFixtureFile(allocator, std.testing.io, path);
    defer allocator.free(source);
    var size_cfg = sizeConfig(rule_set, null);
    size_cfg.applyRunScanMode(scan_mode);
    size_cfg.line_length_limit.options = line_length_options;
    return docent.lintSizeSource(allocator, source, display, size_cfg);
}

fn complexityConfig(
    rule_set: docent.RuleSeverities,
    configure: ?*const fn (*docent.rules.complexity.Complexity) void,
) docent.rules.complexity.Complexity {
    var cfg = docent.rules.complexity.Complexity.defaults();
    cfg.cognitive_complexity.level = rule_set.cognitive_complexity;
    cfg.cyclomatic_complexity.level = rule_set.cyclomatic_complexity;
    if (configure) |configure_fn| configure_fn(&cfg);
    return cfg;
}

pub fn lintComplexityRuleFixture(
    namespace: []const u8,
    parts: []const []const u8,
    rule_set: docent.RuleSeverities,
    display_path: ?[]const u8,
    configure: ?*const fn (*docent.rules.complexity.Complexity) void,
) !docent.LintResult {
    const allocator = std.testing.allocator;
    const path = try ruleFixturePath(allocator, namespace, parts);
    defer allocator.free(path);
    const display = if (display_path) |dp| try allocator.dupe(u8, dp) else try relativeFixtureDisplay(allocator, path);
    defer allocator.free(display);

    const source = try readFixtureFile(allocator, std.testing.io, path);
    defer allocator.free(source);
    const complexity_cfg = complexityConfig(rule_set, configure);
    return docent.lintComplexitySource(allocator, source, display, complexity_cfg);
}

fn sizeConfig(
    rule_set: docent.RuleSeverities,
    configure: ?*const fn (*docent.rules.size.Size) void,
) docent.rules.size.Size {
    var cfg = docent.rules.size.Size.defaults();
    cfg.max_function_parameters.level = rule_set.max_fun_params;
    cfg.line_length_limit.level = rule_set.line_length_limit;
    if (configure) |configure_fn| configure_fn(&cfg);
    return cfg;
}

pub fn lintSizeRuleFixture(
    namespace: []const u8,
    parts: []const []const u8,
    rule_set: docent.RuleSeverities,
    display_path: ?[]const u8,
    configure: ?*const fn (*docent.rules.size.Size) void,
) !docent.LintResult {
    const allocator = std.testing.allocator;
    const path = try ruleFixturePath(allocator, namespace, parts);
    defer allocator.free(path);
    const display = if (display_path) |dp| try allocator.dupe(u8, dp) else try relativeFixtureDisplay(allocator, path);
    defer allocator.free(display);

    const source = try readFixtureFile(allocator, std.testing.io, path);
    defer allocator.free(source);
    const size_cfg = sizeConfig(rule_set, configure);
    return docent.lintSizeSource(allocator, source, display, size_cfg);
}

/// One row for `expectRuleFixtureTable`.
pub const RuleFixtureCase = struct {
    parts: []const []const u8,
    expect_count: usize,
    /// When null, counts every diagnostic; otherwise only this rule id.
    rule: ?[]const u8 = null,
};

/// Runs several fixture cases with the same rule set and asserts expected counts.
pub fn expectRuleFixtureTable(
    namespace: []const u8,
    cases: []const RuleFixtureCase,
    rule_set: docent.RuleSeverities,
    options: docent.LintOptions,
) !void {
    for (cases) |case| {
        var result = try lintRuleFixture(namespace, case.parts, rule_set, options);
        defer result.deinit();
        if (case.rule) |rule| {
            try utils.expectRuleCount(result, rule, case.expect_count);
        } else {
            try std.testing.expectEqual(case.expect_count, result.diagnostics.items.len);
        }
    }
}
