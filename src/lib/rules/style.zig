//! The style namespace gathers style-related rules.
const scan_modes = @import("../scan_modes.zig");

/// Default declaration scanning mode for style rules.
pub const default_scan_mode = scan_modes.Mode.reachability_traversal;

pub const identifier_case = @import("style/identifier_case.zig");
pub const loc_column_length = @import("style/loc_column_length.zig");
