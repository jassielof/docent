//! Effective per-rule severity levels for a lint run.
//!
//! Defaults are sourced from each rule module's `default_severity`. Project config overrides
//! the returned value; see `rule_metadata` for summaries.
const severity = @import("severity.zig");
const rules = @import("rules.zig");

missing_doc_comment: severity.Level = rules.doc.missing_doc_comment.default_severity,
missing_doctest: severity.Level = rules.doc.missing_doctest.default_severity,
private_doctest: severity.Level = rules.doc.private_doctest.default_severity,
blank_doc_comment: severity.Level = rules.doc.blank_doc_comment.default_severity,
missing_summary_terminal_punctuation: severity.Level = rules.doc.missing_summary_terminal_punctuation.default_severity,
trailing_blank_doc_comment: severity.Level = rules.doc.trailing_blank_doc_comment.default_severity,
doctest_naming_mismatch: severity.Level = rules.doc.doctest_naming_mismatch.default_severity,
invalid_leading_phrase: severity.Level = rules.doc.invalid_leading_phrase.default_severity,
cognitive_complexity: severity.Level = rules.complexity.cognitive.default_severity,
cyclomatic_complexity: severity.Level = rules.complexity.cyclomatic.default_severity,
max_fun_params: severity.Level = rules.complexity.max_fun_params.default_severity,
identifier_case: severity.Level = rules.style.identifier_case.default_severity,
line_length_limit: severity.Level = rules.style.line_length_limit.default_severity,

/// Comptime-computed array of all rule field names in declaration order.
const _field_names_buf = init: {
    const fields = @typeInfo(@This()).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| names[i] = f.name;
    break :init names;
};

/// Returns a slice of all rule field names in declaration order.
pub fn fieldNames() []const []const u8 {
    return &_field_names_buf;
}
