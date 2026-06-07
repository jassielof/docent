//! The docs namespace gathers related rules to the doc comments and doctests.
//!
//! By default, these rules are enforced across the public API surface. It is configurable to
//! selectively or completely include non-public declarations too.
//!
//! ## Diagnostic specializations
//!
//! To help with clarification and context, several rules share the same subject resolution:
//!
//! - **Missing module doc comment** — file-level `//!` on module entry roots (`root.zig` and
//!   library `root_source_file` paths from `build.zig`).
//! - **Missing source-file doc comment** — file-level `//!` on implicit structure files and
//!   namespaces (files without struct fields at file scope).
const std = @import("std");

const Config = @import("../schemas/Config.zig");
const scanning = @import("../scanning.zig");

/// Default declaration scanning mode for documentation rules.
pub const default_scan_mode = scanning.Modes.public_api_surface;

pub const missing_doc_comment = @import("docs/missing_doc_comment.zig");
pub const blank_doc_comment = @import("docs/blank_doc_comment.zig");
pub const trailing_blank_doc_comment = @import("docs/trailing_blank_doc_comment.zig");
pub const missing_doctest = @import("docs/missing_doctest.zig");
pub const private_doctest = @import("docs/private_doctest.zig");
pub const doctest_naming_mismatch = @import("docs/doctest_naming_mismatch.zig");
pub const missing_summary_terminal_punctuation = @import("docs/missing_summary_terminal_punctuation.zig");
pub const invalid_leading_phrase = @import("docs/invalid_leading_phrase.zig");

/// Resolved per-rule options for a documentation lint run.
pub const Options = struct {
    missing_doc_comment: missing_doc_comment.Options = .{},
    blank_doc_comment: blank_doc_comment.Options = .{},
    trailing_blank_doc_comment: trailing_blank_doc_comment.Options = .{},
    missing_summary_terminal_punctuation: missing_summary_terminal_punctuation.Options = .{},
    missing_doctest: missing_doctest.Options = .{},
    private_doctest: private_doctest.Options = .{},
    doctest_naming_mismatch: doctest_naming_mismatch.Options = .{},
    invalid_leading_phrase: invalid_leading_phrase.Options = .{},

    /// Resolves effective options from a typed `[docs]` config section.
    pub fn resolve(section: Config.Docs) Options {
        const category_scan = section.scan_mode orelse default_scan_mode;
        return .{
            .missing_doc_comment = missing_doc_comment.Options.resolve(category_scan, section.missing_doc_comment),
            .blank_doc_comment = blank_doc_comment.Options.resolve(category_scan, section.blank_doc_comment),
            .trailing_blank_doc_comment = trailing_blank_doc_comment.Options.resolve(category_scan, section.trailing_blank_doc_comment),
            .missing_summary_terminal_punctuation = missing_summary_terminal_punctuation.Options.resolve(category_scan, section.missing_summary_terminal_punctuation),
            .missing_doctest = missing_doctest.Options.resolve(category_scan, section.missing_doctest),
            .private_doctest = private_doctest.Options.resolve(category_scan, section.private_doctest),
            .doctest_naming_mismatch = doctest_naming_mismatch.Options.resolve(category_scan, section.doctest_naming_mismatch),
            .invalid_leading_phrase = invalid_leading_phrase.Options.resolve(category_scan, section.invalid_leading_phrase),
        };
    }

    /// Library defaults when no config file is present.
    pub fn defaults() Options {
        return resolve(.{});
    }

    /// Overrides every rule's scan mode for a single lint invocation (e.g. explicit path targets).
    pub fn applyRunScanMode(self: *Options, mode: scanning.Modes) void {
        inline for (std.meta.fields(@This())) |field| {
            @field(self, field.name).scan_mode = mode;
        }
    }
};
