const Severity = @import("Severity.zig");

missing_doc_comment: Severity.Level = .warn,
missing_doctest: Severity.Level = .allow,
private_doctest: Severity.Level = .warn,
// COMPAT: //! top-level doc comments — remove if deprecated in 0.16
missing_container_doc_comment: Severity.Level = .allow,
empty_doc_comment: Severity.Level = .warn,
doctest_naming_mismatch: Severity.Level = .warn,
