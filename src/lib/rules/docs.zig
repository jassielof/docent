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
const toml = @import("toml");

const rule_config = @import("config.zig");
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

/// Typed `[docs]` configuration section.
pub const Section = struct {
    scan_mode: ?scanning.Modes = null,
    missing_doc_comment: missing_doc_comment.Config = .{},
    blank_doc_comment: blank_doc_comment.Config = .{},
    trailing_blank_doc_comment: trailing_blank_doc_comment.Config = .{},
    missing_summary_terminal_punctuation: missing_summary_terminal_punctuation.Config = .{},
    missing_doctest: missing_doctest.Config = .{},
    private_doctest: private_doctest.Config = .{},
    doctest_naming_mismatch: doctest_naming_mismatch.Config = .{},
    invalid_leading_phrase: invalid_leading_phrase.Config = .{},
};

pub fn decodeSection(section: *const toml.Table) rule_config.Error!Section {
    var docs: Section = .{};
    if (section.get("scan_mode")) |value| docs.scan_mode = try rule_config.decodeScanModeValue(value);
    if (section.get("missing_doc_comment")) |value| docs.missing_doc_comment = try missing_doc_comment.decodeConfig(value);
    if (section.get("blank_doc_comment")) |value| docs.blank_doc_comment = try rule_config.decodeRuleSimple(value);
    if (section.get("trailing_blank_doc_comment")) |value| docs.trailing_blank_doc_comment = try rule_config.decodeRuleSimple(value);
    if (section.get("missing_summary_terminal_punctuation")) |value| docs.missing_summary_terminal_punctuation = try rule_config.decodeRuleSimple(value);
    if (section.get("missing_doctest")) |value| docs.missing_doctest = try rule_config.decodeRuleSimple(value);
    if (section.get("private_doctest")) |value| docs.private_doctest = try rule_config.decodeRuleSimple(value);
    if (section.get("doctest_naming_mismatch")) |value| docs.doctest_naming_mismatch = try rule_config.decodeRuleSimple(value);
    if (section.get("invalid_leading_phrase")) |value| docs.invalid_leading_phrase = try invalid_leading_phrase.decodeConfig(value);
    return docs;
}

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

    /// Resolves effective options from a typed docs config section.
    pub fn resolve(section: Section) Options {
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
