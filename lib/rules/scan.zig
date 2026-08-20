//! Re-exports declaration-visibility configuration for rule consumers.

const lint = @import("lint");
pub const RuleScanConfig = lint.scan.RuleScanConfig;
pub const Visibility = lint.scan.Visibility;

pub const alias = @import("scan/alias.zig");
