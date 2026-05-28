//! The rules namespace organizes the various linting rules that can be applied to source code.

pub const style = @import("rules/style.zig");
pub const complexity = @import("rules/complexity.zig");
pub const docs = @import("rules/docs.zig");

// TODO: These should be moved under the `docs` namespace as well as under the `rules/docs` directory.
pub const missing_doc_comment = @import("rules/missing_doc_comment.zig");
pub const empty_doc_comment = @import("rules/empty_doc_comment.zig");
pub const missing_doctest = @import("rules/missing_doctest.zig");
pub const private_doctest = @import("rules/private_doctest.zig");
pub const doctest_naming_mismatch = @import("rules/doctest_naming_mismatch.zig");
// COMPAT: //! top-level doc comments — remove if deprecated in 0.16
// Top level comments might be moved to simply:
// /// <Doc comment content>
// const Self = @This()
pub const missing_container_doc_comment = @import("rules/missing_container_doc_comment.zig");
