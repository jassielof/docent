//! Per-run thresholds for the complexity rules, loaded from project config.

const cognitive = @import("rules/complexity/cognitive.zig");

/// Maximum allowed cognitive complexity before a function is flagged.
cognitive_threshold: u32 = cognitive.default_threshold,
