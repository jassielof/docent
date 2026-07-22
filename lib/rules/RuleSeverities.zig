//! Effective per-rule severity levels for a lint run.
//!
//! Defaults are sourced from each rule module's `default_severity`. Project config overrides
//! the returned value. Each rule module also exports `prose_title` for diagnostic messages.
const doc = @import("doc.zig");
const style = @import("style.zig");
const complexity = @import("complexity.zig");
const size = @import("size.zig");
const severity = @import("severity.zig");

missing_doc_comment: severity.Level = doc.missing_doc_comment.default_severity,
missing_doctest: severity.Level = doc.missing_doctest.default_severity,
private_doctest: severity.Level = doc.private_doctest.default_severity,
blank_doc_comment: severity.Level = doc.blank_doc_comment.default_severity,
missing_summary_terminal_punctuation: severity.Level = doc.missing_summary_terminal_punctuation.default_severity,
trailing_blank_doc_comment: severity.Level = doc.trailing_blank_doc_comment.default_severity,
doctest_naming_mismatch: severity.Level = doc.doctest_naming_mismatch.default_severity,
invalid_leading_phrase: severity.Level = doc.invalid_leading_phrase.default_severity,
redundant_doc_comment: severity.Level = doc.redundant_doc_comment.default_severity,
cognitive_complexity: severity.Level = complexity.cognitive.default_severity,
cyclomatic_complexity: severity.Level = complexity.cyclomatic.default_severity,
max_fun_params: severity.Level = size.max_fun_params.default_severity,
line_length_limit: severity.Level = size.line_length_limit.default_severity,
identifier_case: severity.Level = style.identifier_case.default_severity,

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
