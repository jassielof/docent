//! The docs namespace gathers documentation comment related rules.

pub const missing_doc_comment = @import("docs/missing_doc_comment.zig");
pub const blank_doc_comment = @import("docs/blank_doc_comment.zig");
pub const missing_doctest = @import("docs/missing_doctest.zig");
pub const private_doctest = @import("docs/private_doctest.zig");
pub const doctest_naming_mismatch = @import("docs/doctest_naming_mismatch.zig");
pub const missing_container_doc_comment = @import("docs/missing_container_doc_comment.zig");

pub const missing_summary_terminal_punctuation = @import("docs/missing_summary_terminal_punctuation.zig");
pub const starts_with_leading_phrase = @import("docs/starts_with_leading_phrase.zig");
