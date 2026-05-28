//! Per-rule severity defaults for a lint run.
//!
//! Each field names a rule and holds its effective level (`allow`, `warn`, `deny`, or `forbid`).
//! Override levels via project config; see `rule_metadata` for summaries.
const Severity = @import("Severity.zig");

/// Checks for public declarations without doc comments.
///
/// ## Re-exports
///
/// Check the `reexport` fixture for how this is applied, the resolution needs to perform a full project or API reachability analysis (traversal).
missing_doc_comment: Severity.Level = .warn,
/// Suggests runnable `///` examples on public functions when enabled.
missing_doctest: Severity.Level = .allow,
/// Flags doc comments on private declarations that look like public doctests.
private_doctest: Severity.Level = .warn,
/// Checks library entry points for a file-level `//!` doc comment (the implicit module container only).
///
/// ## Possible removal
///
/// Top-level doc comments (`//!`) are being considered for removal. The rule will be kept until they are removed. Relevant issue: <https://codeberg.org/ziglang/zig/issues/30132>
missing_container_doc_comment: Severity.Level = .warn,
/// Requires non-empty text in doc comments.
empty_doc_comment: Severity.Level = .warn,
/// Requires doctest names to match the declaration they document.
doctest_naming_mismatch: Severity.Level = .warn,

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
