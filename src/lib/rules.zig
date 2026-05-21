//! Rule implementation modules used by `lintSource`.

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
