//! The set of rules used by the linter.
const Severity = @import("Severity.zig");

/// Checks for public declarations without doc comments.
///
/// ## Re-exports
///
/// Check the `reexport` fixture for how this is applied, the resolution needs to perform a full project or API reachability analysis (traversal).
missing_doc_comment: Severity.Level = .warn,
missing_doctest: Severity.Level = .allow,
private_doctest: Severity.Level = .warn,
/// Checks for modules missing a top-level doc comment (`//!`).
///
/// ## Possible removal
///
/// TODO: Top-level doc comments (`//!`) are being considered for removal. The rule will be kept until they are removed, so the rule analysis needs to be implmented in a way that it can be easily disabled or removed.
/// Relevant issue: <https://codeberg.org/ziglang/zig/issues/30132>
missing_container_doc_comment: Severity.Level = .allow,
empty_doc_comment: Severity.Level = .warn,
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
/// Use this to keep `--rule` flag `allowed_keys` in sync with the struct automatically — adding a new field here makes it available in the CLI without any manual update.
pub fn fieldNames() []const []const u8 {
    return &_field_names_buf;
}
