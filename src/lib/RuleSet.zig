//! Per-rule severity defaults for a lint run.
//!
//! Each field names a rule and holds its effective level (`allow`, `warn`, `deny`, or `forbid`).
//! Override levels via project config; see `rule_metadata` for summaries.
const severity = @import("severity.zig");

/// Checks for missing doc comments on public API items, module roots (`//!`), and re-exported source files.
///
/// ## Re-exports
///
/// Check the `reexport` fixture for how this is applied, the resolution needs to perform a full project or API reachability analysis (traversal).
missing_doc_comment: severity.Level = .warn,
/// Suggests runnable `///` examples on public functions when enabled.
missing_doctest: severity.Level = .allow,
/// Flags doc comments on private declarations that look like public doctests.
private_doctest: severity.Level = .warn,
/// Requires non-blank text in doc comments.
blank_doc_comment: severity.Level = .warn,
/// Requires the first doc-comment paragraph to end with `.`, `!`, or `?`.
missing_summary_terminal_punctuation: severity.Level = .warn,
/// Requires doc comment blocks not to end with trailing blank lines.
trailing_blank_doc_comment: severity.Level = .warn,
/// Requires doctest names to match the declaration they document.
doctest_naming_mismatch: severity.Level = .warn,
/// Requires the summary to begin with a valid leading phrase naming the documented identifier.
invalid_leading_phrase: severity.Level = .warn,
/// Flags functions whose cognitive complexity exceeds the configured threshold (default 15).
///
/// Measured by the `docent complexity` sub-command following the Sonar specification; not part of the default lint run.
cognitive_complexity: severity.Level = .warn,
/// Flags functions whose cyclomatic complexity exceeds the configured threshold (default 10).
///
/// Measured by the `docent complexity` sub-command following the McCabe definition; not part of the default lint run.
cyclomatic_complexity: severity.Level = .allow,
/// Flags functions with more parameters than the configured limit (default 7).
///
/// Measured by the `docent complexity` sub-command; not part of the default lint run.
max_fun_params: severity.Level = .warn,
/// Flags identifiers that don't follow the Zig naming-case conventions.
///
/// Reported by the `docent style` sub-command rather than the default lint run.
identifier_case: severity.Level = .warn,

/// Comptime-computed array of all rule field names in declaration order.
const _field_names_buf = init: {
    const fields = @typeInfo(@This()).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| names[i] = f.name;
    break :init names;
};

/// Returns a slice of all rule field names in declaration order.
///
/// Field names for config loaders and diagnostics; adding a field here should be reflected in `rule_metadata`.
pub fn fieldNames() []const []const u8 {
    return &_field_names_buf;
}
