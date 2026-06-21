//! Per-file options for `lintSource` / `lintFile`.

const scan = @import("scan.zig");

/// When set to `public_api_surface`, only `pub` declarations are checked; `reachability_traversal`
/// includes every declaration in reachable files.
scan_mode: scan.RuleScanConfig = .public_api_surface,
/// Package or module name for module-doc diagnostics (from `build.zig.zon` when available).
module_name: ?[]const u8 = null,

/// Returns whether rule checks should skip non-public declarations.
pub fn publicApiOnly(options: @This()) bool {
    return options.scan_mode.publicApiOnly();
}
