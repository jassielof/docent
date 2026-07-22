//! Source code formatting: Zig AST render plus configurable post-passes.
//!
//! By default Docent applies a gofumpt-style superset of Zig's formatting
//! rules, while still allowing projects to tune or disable each pass via
//! `[fmt]` in `.config/docent.toml`.
//!
//! ## References
//!
//! - [Zig's main formatting implementation](https://codeberg.org/ziglang/zig/src/tag/0.16.0/src/fmt.zig)
//! - [gofumpt](https://github.com/mvdan/gofumpt)
// TODO: The check diff diagnostics mix up the slashes (I'm on Windows):
// ```
// lib/fmt\Formatter.zig
// lib/fmt\root.zig
// internal/docent\root.zig
// ```
// These are set as `include = ["lib/", "internal/"]` which isn't normalized, Vereda might help with path normalization.

const std = @import("std");

pub const array_type_guard = @import("array_type_guard.zig");
pub const findPathologicalArrayType = array_type_guard.findPathologicalArrayType;
pub const auto_wrap = @import("auto_wrap.zig");
pub const autoWrap = auto_wrap.autoWrap;
pub const brace_style = @import("brace_style.zig");
pub const convertToAllman = brace_style.convertToAllman;
pub const config = @import("config.zig");
pub const CheckFormat = config.CheckFormat;
pub const Config = config.Config;
pub const BraceStyle = Config.BraceStyle;
pub const IndentStyle = Config.IndentStyle;
pub const Options = config.Options;
pub const diff = @import("diff.zig");
pub const Formatter = @import("Formatter.zig");
pub const grid_alignment = @import("grid_alignment.zig");
pub const alignGrid = grid_alignment.alignGrid;
pub const indent_width = @import("indent_width.zig");
pub const reindent = indent_width.reindent;
pub const logical_blank_lines = @import("logical_blank_lines.zig");
pub const enforceLogicalBlankLines = logical_blank_lines.enforceLogicalBlankLines;
pub const single_line_braces = @import("single_line_braces.zig");
pub const enforceBraces = single_line_braces.enforceBraces;
pub const sort_doctests = @import("sort_doctests.zig");
pub const sortDoctests = sort_doctests.sortDoctests;
pub const sort_imports = @import("sort_imports.zig");
pub const sortImports = sort_imports.sortImports;
pub const symlink_safe_write = @import("symlink_safe_write.zig");
pub const trailing_comma = @import("trailing_comma.zig");
pub const addTrailingCommas = trailing_comma.addTrailingCommas;

comptime {
    std.testing.refAllDecls(@This());
}
