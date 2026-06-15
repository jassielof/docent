//! Human-facing rule titles for diagnostic prose.
//!
//! Rule identifiers and default severities live in `RuleSeverities` and each rule module.
//! Severity level descriptions live in `severity.Level`. This module only resolves the
//! short title shown in messages such as `Warning: Missing doc comment on field 'x'.`

const std = @import("std");
const RuleSeverities = @import("RuleSeverities.zig");
const rules = @import("rules.zig");

fn proseTitleForRule(comptime rule_name: []const u8) []const u8 {
    if (std.mem.eql(u8, rule_name, "missing_doc_comment")) return rules.doc.missing_doc_comment.prose_title;
    if (std.mem.eql(u8, rule_name, "missing_doctest")) return rules.doc.missing_doctest.prose_title;
    if (std.mem.eql(u8, rule_name, "private_doctest")) return rules.doc.private_doctest.prose_title;
    if (std.mem.eql(u8, rule_name, "blank_doc_comment")) return rules.doc.blank_doc_comment.prose_title;
    if (std.mem.eql(u8, rule_name, "missing_summary_terminal_punctuation")) return rules.doc.missing_summary_terminal_punctuation.prose_title;
    if (std.mem.eql(u8, rule_name, "trailing_blank_doc_comment")) return rules.doc.trailing_blank_doc_comment.prose_title;
    if (std.mem.eql(u8, rule_name, "doctest_naming_mismatch")) return rules.doc.doctest_naming_mismatch.prose_title;
    if (std.mem.eql(u8, rule_name, "invalid_leading_phrase")) return rules.doc.invalid_leading_phrase.prose_title;
    if (std.mem.eql(u8, rule_name, "cognitive_complexity")) return rules.complexity.cognitive.prose_title;
    if (std.mem.eql(u8, rule_name, "cyclomatic_complexity")) return rules.complexity.cyclomatic.prose_title;
    if (std.mem.eql(u8, rule_name, "max_fun_params")) return rules.complexity.max_fun_params.prose_title;
    if (std.mem.eql(u8, rule_name, "identifier_case")) return rules.style.identifier_case.prose_title;
    if (std.mem.eql(u8, rule_name, "line_length_limit")) return rules.style.line_length_limit.prose_title;
    @compileError("missing prose_title mapping for rule: " ++ rule_name);
}

const prose_titles = blk: {
    const names = RuleSeverities.fieldNames();
    var entries: [names.len]struct { []const u8, []const u8 } = undefined;
    for (names, 0..) |name, i| {
        entries[i] = .{ name, proseTitleForRule(name) };
    }
    break :blk entries;
};

/// Returns the prose title for `rule_name`, or null when unknown.
pub fn proseTitle(rule_name: []const u8) ?[]const u8 {
    for (prose_titles) |entry| {
        if (std.mem.eql(u8, entry[0], rule_name)) return entry[1];
    }
    return null;
}

comptime {
    for (prose_titles, RuleSeverities.fieldNames()) |entry, name| {
        if (!std.mem.eql(u8, entry[0], name)) {
            @compileError("prose title table order must match RuleSeverities fields");
        }
    }
}
