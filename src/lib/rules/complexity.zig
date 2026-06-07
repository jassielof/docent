//! The complexity namespace gathers complexity-related rules.
const scan_modes = @import("../scan_modes.zig");

/// Default declaration scanning mode for complexity rules.
pub const default_scan_mode = scan_modes.Mode.reachability_traversal;

pub const cognitive = @import("complexity/cognitive.zig");
pub const cyclomatic = @import("complexity/cyclomatic.zig");
pub const max_fun_params = @import("complexity/max_fun_params.zig");
