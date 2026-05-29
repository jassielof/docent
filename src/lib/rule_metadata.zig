//! Single source for human-facing rule names, defaults, and summaries shared by CLI help, docs, and completions.
const std = @import("std");
const RuleSet = @import("RuleSet.zig");

/// One rule entry for CLI help, docs, and shell completions.
pub const RuleRow = struct {
    /// Rule identifier (matches `RuleSet` field names).
    name: []const u8,
    /// Default severity string (`allow`, `warn`, `deny`, or `forbid`).
    default_level: []const u8,
    /// Short one-line description shown in help output.
    summary: []const u8,
    /// Title used in diagnostic prose (`Warning: {prose_title} on …`).
    prose_title: []const u8,
    /// Optional extended help; empty when unused.
    long: []const u8 = "",
};

/// Returns the prose title for `rule_name`, or null when unknown.
pub fn proseTitle(rule_name: []const u8) ?[]const u8 {
    for (rules) |row| {
        if (std.mem.eql(u8, row.name, rule_name)) return row.prose_title;
    }
    return null;
}

/// Severity levels documented for project config (order matches public explanations).
pub const levels: []const struct { name: []const u8, summary: []const u8 } = &.{
    .{ .name = "allow", .summary = "Disable the rule." },
    .{ .name = "warn", .summary = "Report diagnostics without failing the process." },
    .{ .name = "deny", .summary = "Report diagnostics and exit with an error." },
    .{ .name = "forbid", .summary = "Like deny, but cannot be relaxed by later overrides." },
};

/// Rule catalog in the same field order as `RuleSet`.
pub const rules: []const RuleRow = &.{
    .{
        .name = "missing_doc_comment",
        .default_level = "warn",
        .summary = "Public API items, module roots, and exposed source files should have doc comments.",
        .prose_title = "Missing doc comment",
    },
    .{
        .name = "missing_doctest",
        .default_level = "allow",
        .summary = "Public functions may include runnable examples.",
        .prose_title = "Missing doctest",
    },
    .{
        .name = "private_doctest",
        .default_level = "warn",
        .summary = "Private declarations should not carry identifier-style doctests.",
        .prose_title = "Private doctest",
    },
    .{
        .name = "blank_doc_comment",
        .default_level = "warn",
        .summary = "Doc comments should contain useful text (not blank or whitespace-only).",
        .prose_title = "Blank doc comment",
    },
    .{
        .name = "missing_summary_terminal_punctuation",
        .default_level = "warn",
        .summary = "The first paragraph of a doc comment should end with `.`, `!`, or `?`.",
        .prose_title = "Missing summary terminal punctuation",
    },
    .{
        .name = "trailing_blank_doc_comment",
        .default_level = "warn",
        .summary = "Doc comments should not end with blank lines.",
        .prose_title = "Trailing blank doc comment",
    },
    .{
        .name = "doctest_naming_mismatch",
        .default_level = "warn",
        .summary = "Doctest names should match the declaration they document.",
        .prose_title = "Doctest naming mismatch",
    },
    .{
        .name = "invalid_leading_phrase",
        .default_level = "warn",
        .summary = "Doc comment summaries should begin with a leading phrase naming the documented identifier.",
        .prose_title = "Invalid leading phrase",
    },
};

comptime {
    const fnames = RuleSet.fieldNames();
    if (rules.len != fnames.len)
        @compileError("rule_metadata.rules length must match RuleSet fields");

    for (rules, fnames) |row, n| {
        if (!std.mem.eql(u8, row.name, n)) @compileError("rule_metadata.rules order/names must match RuleSet fields");
    }

    const defs: RuleSet = .{};
    for (rules, std.meta.fields(RuleSet)) |row, f| {
        const expected = @tagName(@field(defs, f.name));
        if (!std.mem.eql(u8, row.default_level, expected)) {
            @compileError("rule_metadata default_level does not match RuleSet field default");
        }
    }
}

/// How later config overrides interact with `forbid`.
pub const override_behavior_note =
    \\Override order:
    \\  Later overrides win, except when a rule has already been set to forbid.
;
