//! Formatter configuration: TOML `[fmt]` knobs and CLI/runtime options.

const std = @import("std");
const Color = std.zig.Color;

const brace_style = @import("brace_style.zig");
const indent_width = @import("indent_width.zig");

/// Persisted `[fmt]` options from `.config/docent.toml`.
///
/// Defaults follow a gofumpt-style model: stricter than Zig's own formatter
/// where it helps consistency (`single_line_braces`, `trailing_comma`,
/// `logical_blank_lines`, `sort_imports`), while leaving controversial or
/// zig-fmt-hostile transforms (`auto_wrap`, `grid_alignment`) off by default.
pub const Config = struct {
    brace_style: BraceStyle = .k_r,
    single_line_braces: bool = true,
    trailing_comma: bool = true,
    logical_blank_lines: bool = true,
    sort_imports: bool = true,
    indent_style: IndentStyle = .space,
    indent_width: u8 = 4,
    /// Best-effort wrap of over-long lines via list/call expansion. Off by
    /// default (gofumpt also does not wrap).
    auto_wrap: bool = false,
    /// Column budget used when `auto_wrap` is enabled. Matches the lint
    /// rule `line_length_limit` default.
    max_line_length: u32 = 100,
    /// Column-align `:` / `=` in contiguous field and decl groups. Off by
    /// default because Zig's AST renderer left-flushes; Docent re-applies
    /// this pass every run when enabled.
    grid_alignment: bool = false,

    /// The brace style enum and its `fromConfigString` live in
    /// `brace_style.zig`, next to the transform logic that consumes it
    /// (same convention as `naming_case.Style`) -- kept as `BraceStyle` here
    /// for backward compatibility with existing `Config.Fmt.BraceStyle` /
    /// `Fmt.BraceStyle` references.
    pub const BraceStyle = brace_style.Style;

    /// See `BraceStyle` above -- same convention, owned by `indent_width.zig`.
    pub const IndentStyle = indent_width.Style;
};

pub const CheckFormat = enum { pretty, minimal };

/// CLI/runtime options (not persisted in TOML).
pub const Options = struct {
    check: bool = false,
    check_format: CheckFormat = .pretty,
    ast_check: bool = false,
    zon: bool = false,
    color: Color = .auto,
};
