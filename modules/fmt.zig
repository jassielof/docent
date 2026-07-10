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

pub const config = @import("fmt/config.zig");
pub const Config = config.Config;
pub const Options = config.Options;
pub const CheckFormat = config.CheckFormat;
pub const BraceStyle = Config.BraceStyle;
pub const IndentStyle = Config.IndentStyle;

pub const Formatter = @import("fmt/Formatter.zig");

pub const brace_style = @import("fmt/brace_style.zig");
pub const convertToAllman = brace_style.convertToAllman;
pub const single_line_braces = @import("fmt/single_line_braces.zig");
pub const enforceBraces = single_line_braces.enforceBraces;
pub const trailing_comma = @import("fmt/trailing_comma.zig");
pub const addTrailingCommas = trailing_comma.addTrailingCommas;
pub const logical_blank_lines = @import("fmt/logical_blank_lines.zig");
pub const enforceLogicalBlankLines = logical_blank_lines.enforceLogicalBlankLines;
pub const sort_imports = @import("fmt/sort_imports.zig");
pub const sortImports = sort_imports.sortImports;
pub const indent_width = @import("fmt/indent_width.zig");
pub const reindent = indent_width.reindent;
pub const auto_wrap = @import("fmt/auto_wrap.zig");
pub const autoWrap = auto_wrap.autoWrap;
pub const grid_alignment = @import("fmt/grid_alignment.zig");
pub const alignGrid = grid_alignment.alignGrid;
pub const diff = @import("fmt/diff.zig");
