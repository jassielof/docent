//! The docs namespace gathers related rules to the doc comments and doctests.
//!
//! By default, these rules are enforced across the public API surface. It is configurable to
//! selectively or completely include non-public declarations too.
const scan_modes = @import("../scan_modes.zig");

/// Default declaration scanning mode for documentation rules.
pub const default_scan_mode = scan_modes.Mode.public_api_surface;

pub const missing_doc_comment = @import("docs/missing_doc_comment.zig");
pub const blank_doc_comment = @import("docs/blank_doc_comment.zig");
pub const trailing_blank_doc_comment = @import("docs/trailing_blank_doc_comment.zig");
pub const missing_doctest = @import("docs/missing_doctest.zig");
pub const private_doctest = @import("docs/private_doctest.zig");
pub const doctest_naming_mismatch = @import("docs/doctest_naming_mismatch.zig");
pub const missing_summary_terminal_punctuation = @import("docs/missing_summary_terminal_punctuation.zig");
pub const invalid_leading_phrase = @import("docs/invalid_leading_phrase.zig");
