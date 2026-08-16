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
//!
//! ## Broken intra-doc links
//!
//! Zig itself allows it but strictly scoped to symbols within the same file, one cannot reference symbols from other files within the same module, this is done by backticks, but it's not documented, until it's properly designed and documented, this won't be documented. See <https://github.com/ziglang/zig/issues/19866>.
const lint = @import("lint");
const category = lint.category;
const scan = lint.scan;

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
pub const misplaced_doc_comment = @import("doc/misplaced_doc_comment.zig");

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
    // Imported bindings are never a useful location for a doc comment, even when private.
    misplaced_doc_comment: misplaced_doc_comment.Rule = .{ .scan_mode = .reachability_traversal },

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

comptime {
    std.testing.refAllDecls(@This());
}
const std = @import("std");
