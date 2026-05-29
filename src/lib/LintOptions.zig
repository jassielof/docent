//! Per-file options for `lintSource` / `lintFile`.

/// When true, require a file-level `//!` doc comment for this source file.
require_module_doc: bool = false,
/// Package or module name for module-doc diagnostics (from `build.zig.zon` when available).
module_name: ?[]const u8 = null,
