//! `invalid_leading_phrase` — summaries must begin with a valid phrase naming the documented identifier.

const std = @import("std");
const testing = std.testing;
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "doc";
const ConfigureDoc = *const fn (*docent.rules.doc.Doc) void;

const warn = docent.RuleSeverities{ .invalid_leading_phrase = .warn };
const public_surface = docent.LintOptions{ .scan_mode = .public_api_surface };
const reachability = docent.LintOptions{ .scan_mode = .reachability_traversal };

fn lint(
    fixture: []const u8,
    rule_set: docent.RuleSeverities,
    lint_options: docent.LintOptions,
    configure: ?ConfigureDoc,
) !docent.LintResult {
    return harness.lintRuleFixtureConfigured(ns, &.{fixture}, rule_set, lint_options, null, configure);
}

fn expectLeadingPhraseSubject(result: docent.LintResult, kind: docent.Diagnostic.SubjectKind) !void {
    for (result.diagnostics.items) |d| {
        if (!std.mem.eql(u8, d.rule, "invalid_leading_phrase")) continue;
        try testing.expectEqual(kind, d.subject.?.kind);
        return;
    }
    return error.TestExpectedEqual;
}

fn setStrictMode(cfg: *docent.rules.doc.Doc) void {
    cfg.invalid_leading_phrase.options.mode = .strict;
}

fn setRequireArticle(cfg: *docent.rules.doc.Doc) void {
    cfg.invalid_leading_phrase.options.require_article = true;
}

fn setRequireBackticks(cfg: *docent.rules.doc.Doc) void {
    cfg.invalid_leading_phrase.options.require_backticks = true;
}

test "accepts identifier-first summary on a function" {
    var result = try lint("leading_phrase_identifier_first.zig", warn, public_surface, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}

test "accepts kind word before backticked identifier" {
    var result = try lint("leading_phrase_kind_before_backtick.zig", warn, public_surface, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}

test "warns when summary omits the identifier" {
    var result = try lint("invalid_leading_phrase.zig", warn, public_surface, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "invalid_leading_phrase", 1);
    for (result.diagnostics.items) |d| {
        if (!std.mem.eql(u8, d.rule, "invalid_leading_phrase")) continue;
        try testing.expectEqual(.function, d.subject.?.kind);
        try testing.expectEqualStrings("add", d.subject.?.name);
        return;
    }
    return error.TestExpectedEqual;
}

test "warns on identifier case mismatch for declarations" {
    var result = try lint("leading_phrase_case_mismatch.zig", warn, public_surface, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "invalid_leading_phrase", 1);
}

test "accepts struct documented with article and trailing kind" {
    var result = try lint("leading_phrase_struct_article_kind.zig", warn, public_surface, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}

test "accepts error set with article and trailing kind" {
    var result = try lint("leading_phrase_error_set_article_kind.zig", warn, public_surface, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}

test "accepts constant identifier first" {
    var result = try lint("leading_phrase_constant_identifier_first.zig", warn, public_surface, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}

test "module doc accepts case-insensitive name with kind word" {
    var result = try lint("leading_phrase_module_kind_accept.zig", warn, .{ .scan_mode = .public_api_surface, .module_name = "docent" }, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}

test "module doc warns when name is absent" {
    var result = try lint("leading_phrase_module_missing_name.zig", warn, .{ .scan_mode = .public_api_surface, .module_name = "docent" }, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "invalid_leading_phrase", 1);
    try expectLeadingPhraseSubject(result, .module);
}

test "no diagnostic for undocumented or unresolved blocks" {
    var result = try lint("leading_phrase_unattached_doc.zig", warn, public_surface, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}

test "accepts enumerator identifier first" {
    var result = try lint("leading_phrase_enumerator_ok.zig", warn, public_surface, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}

test "no diagnostic for private function doc comment" {
    var result = try lint("leading_phrase_private_fn_skipped.zig", warn, public_surface, null);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}

test "warns on public function when public_api_only" {
    var result = try lint("leading_phrase_public_fn_warn.zig", warn, public_surface, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "invalid_leading_phrase", 1);
}

test "private function checked when public_api_only is false" {
    var result = try lint("leading_phrase_private_fn_all_mode.zig", warn, reachability, null);
    defer result.deinit();
    try utils.expectRuleCount(result, "invalid_leading_phrase", 1);
}

test "strict mode rejects identifier-first function summary" {
    var result = try lint("leading_phrase_identifier_first.zig", warn, public_surface, setStrictMode);
    defer result.deinit();
    try utils.expectRuleCount(result, "invalid_leading_phrase", 1);
}

test "strict mode accepts kind-before identifier summary" {
    var result = try lint("leading_phrase_strict_accept.zig", warn, public_surface, setStrictMode);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}

test "require_article rejects summary without article" {
    var result = try lint("leading_phrase_kind_before_backtick.zig", warn, public_surface, setRequireArticle);
    defer result.deinit();
    try utils.expectRuleCount(result, "invalid_leading_phrase", 1);
}

test "require_article accepts summary with article" {
    var result = try lint("leading_phrase_require_article_accept.zig", warn, public_surface, setRequireArticle);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}

test "require_backticks rejects bare identifier" {
    var result = try lint("leading_phrase_require_backticks_reject.zig", warn, public_surface, setRequireBackticks);
    defer result.deinit();
    try utils.expectRuleCount(result, "invalid_leading_phrase", 1);
}

test "require_backticks accepts backticked identifier" {
    var result = try lint("leading_phrase_require_backticks_accept.zig", warn, public_surface, setRequireBackticks);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}

test "summary_with_leading_identifier_is_accepted via fixture path" {
    var result = try harness.lintRuleFixture(ns, &.{ "leading_phrase_ok.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "invalid_leading_phrase");
}

test "summary_without_identifier_is_reported via fixture path" {
    var result = try harness.lintRuleFixture(ns, &.{ "invalid_leading_phrase.zig" }, warn, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "invalid_leading_phrase", 1);
}
