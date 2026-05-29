//! Per-file options for `lintSource` / `lintFile`.

/// When true, only `pub` declarations are checked; when false, every declaration in the file is checked.
public_api_only: bool = true,
/// Package or module name for module-doc diagnostics (from `build.zig.zon` when available).
module_name: ?[]const u8 = null,
