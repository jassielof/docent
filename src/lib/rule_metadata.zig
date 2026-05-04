//! Single source for human-facing rule names, defaults, and summaries shared by CLI help, docs, and completions.
const std = @import("std");
const RuleSet = @import("RuleSet.zig");

pub const RuleRow = struct {
    name: []const u8,
    default_level: []const u8,
    summary: []const u8,
    long: []const u8 = "",
};

/// Severity levels documented for `--rule` and friends (order matches public explanations).
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
        .summary = "Public declarations should have doc comments.",
    },
    .{
        .name = "missing_doctest",
        .default_level = "allow",
        .summary = "Public functions may include runnable examples.",
    },
    .{
        .name = "private_doctest",
        .default_level = "warn",
        .summary = "Private declarations should not carry identifier-style doctests.",
    },
    .{
        .name = "missing_container_doc_comment",
        .default_level = "allow",
        .summary = "Modules and public containers may include //! documentation.",
    },
    .{
        .name = "empty_doc_comment",
        .default_level = "warn",
        .summary = "Doc comments should contain useful text.",
    },
    .{
        .name = "doctest_naming_mismatch",
        .default_level = "warn",
        .summary = "Doctest names should match the declaration they document.",
    },
};

comptime {
    const fnames = RuleSet.fieldNames();
    if (rules.len != fnames.len) @compileError("rule_metadata.rules length must match RuleSet fields");
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

pub const override_behavior_note =
    \\Override order:
    \\  Later overrides win, except when a rule has already been set to forbid.
;
