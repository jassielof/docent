//! Per-file options for `lintSource` / `lintFile`.

const lint = @import("lint");
const scan = lint.scan;

/// When set to `public_declarations`, only `pub` declarations are checked; `all_declarations` includes every declaration in the file.
scan_mode: scan.RuleScanConfig = .public_declarations,
/// Package or module name for module-doc diagnostics (from `build.zig.zon` when available).
module_name: ?[]const u8 = null,

/// Returns whether rule checks should skip non-public declarations.
pub fn publicDeclarationsOnly(options: @This()) bool {
    return options.scan_mode.publicDeclarationsOnly();
}
