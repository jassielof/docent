//! Per-run thresholds for the complexity rules, loaded from project config.

const cognitive = @import("rules/complexity/cognitive.zig");
const max_fun_params = @import("rules/complexity/max_fun_params.zig");

/// Maximum allowed cognitive complexity before a function is flagged.
cognitive_threshold: u32 = cognitive.default_threshold,
/// Maximum allowed function parameter count before a function is flagged.
max_fun_params_threshold: u32 = max_fun_params.default_threshold,
