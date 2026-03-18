const Severity = @import("Severity.zig");

missing_doc_comment: Severity.Level = .warn,
missing_doctest: Severity.Level = .allow,
private_doctest: Severity.Level = .warn,
// COMPAT: //! top-level doc comments — remove if deprecated in 0.16
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
/// Use this to keep `--rule` flag `allowed_keys` in sync with the struct
/// automatically — adding a new field here makes it available in the CLI
/// without any manual update.
pub fn fieldNames() []const []const u8 {
    return &_field_names_buf;
}
