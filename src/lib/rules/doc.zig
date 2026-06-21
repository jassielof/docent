//! The doc namespace gathers related rules for doc comments and doctests.
//!
//! By default, these rules are enforced across the public API surface. It is configurable to selectively or completely include non-public declarations too.
//!
//! ## Diagnostic specializations
//!
//! To help with clarification and context, several rules share the same subject resolution:
//!
//! - **Missing module doc comment** — file-level `//!` on module entry roots (`root.zig` and library `root_source_file` paths from `build.zig`).
//! - **Missing source-file doc comment** — file-level `//!` on implicit structure files and namespaces (files without struct fields at file scope).
const scan = @import("../scan.zig");
const category = @import("category.zig");

/// Default scan mode for documentation rules; `public_api_surface` because doc comments are enforced on the public API by default.
pub const default_scan_mode: scan.RuleScanConfig = .public_api_surface;

pub const missing_doc_comment = @import("doc/missing_doc_comment.zig");
pub const blank_doc_comment = @import("doc/blank_doc_comment.zig");
pub const trailing_blank_doc_comment = @import("doc/trailing_blank_doc_comment.zig");
pub const missing_doctest = @import("doc/missing_doctest.zig");
pub const private_doctest = @import("doc/private_doctest.zig");
pub const doctest_naming_mismatch = @import("doc/doctest_naming_mismatch.zig");
pub const missing_summary_terminal_punctuation = @import("doc/missing_summary_terminal_punctuation.zig");
pub const invalid_leading_phrase = @import("doc/invalid_leading_phrase.zig");
// TODO: Maybe add a "redundant doc comment" rule, which would flag (usually) re-exported alias declarations that have their own doc comment, for example:
// ```zig
// // root.zig
// /// a doc comment for scan.zig
// pub const scan = @import("scan.zig");
//
// // scan.zig
// //! the main doc comment for the scan.zig file.
// ...
// ```
//
// The reundant doc comment in this case would be the one in `root.zig` as the scan namespace/file already has its own doc comment, and this can cause just redundancy issues or ambiguity.

/// The `doc` configuration: the category-wide scan mode plus each rule's config, decoded generically and resolved in place.
pub const Doc = struct {
    /// Category-wide scan mode; rules with a `null` scan mode inherit this value.
    scan_mode: scan.RuleScanConfig = default_scan_mode,
    missing_doc_comment: missing_doc_comment.Rule = .{},
    blank_doc_comment: blank_doc_comment.Rule = .{},
    trailing_blank_doc_comment: trailing_blank_doc_comment.Rule = .{},
    missing_summary_terminal_punctuation: missing_summary_terminal_punctuation.Rule = .{},
    missing_doctest: missing_doctest.Rule = .{},
    private_doctest: private_doctest.Rule = .{},
    doctest_naming_mismatch: doctest_naming_mismatch.Rule = .{},
    invalid_leading_phrase: invalid_leading_phrase.Rule = .{},

    /// Returns the library defaults with scan-mode inheritance already applied.
    pub fn defaults() Doc {
        var doc: Doc = .{};
        doc.resolveScanModes();
        return doc;
    }

    /// Fills each rule's unset (`null`) scan mode with the category default; call once after decoding.
    pub fn resolveScanModes(self: *Doc) void {
        category.resolveScanModes(self);
    }

    /// Overrides every rule's scan mode for a single lint invocation, such as explicit path targets.
    pub fn applyRunScanMode(self: *Doc, mode: scan.RuleScanConfig) void {
        category.applyRunScanMode(self, mode);
    }
};
