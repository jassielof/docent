//! The complexity namespace gathers complexity-related rules.
const std = @import("std");

const lint = @import("lint");
const category = lint.category;
const scan = lint.scan;
/// Default scan mode for complexity rules; `all_declarations` because every reachable function is measured, not just the public surface.
pub const default_scan_mode = scan.RuleScanConfig.all_declarations;

pub const cognitive = @import("cogni");
pub const cyclomatic = @import("cyclo");

/// The `complexity` configuration: the category-wide scan mode plus each rule's config, decoded generically and resolved in place.
pub const Complexity = struct {
    /// Category-wide scan mode; rules with a `null` scan mode inherit this value.
    scan_mode: scan.RuleScanConfig = default_scan_mode,
    cognitive_complexity: cognitive.Rule = .{},
    cyclomatic_complexity: cyclomatic.Rule = .{},

    /// Returns the library defaults with scan-mode inheritance already applied.
    pub fn defaults() Complexity {
        var complexity: Complexity = .{};
        complexity.resolveScanModes();
        return complexity;
    }

    /// Fills each rule's unset (`null`) scan mode with the category default; call once after decoding.
    pub fn resolveScanModes(self: *Complexity) void {
        category.resolveScanModes(self);
    }

    /// Overrides every rule's scan mode for a single lint invocation, such as explicit path targets.
    pub fn applyRunScanMode(self: *Complexity, mode: scan.RuleScanConfig) void {
        category.applyRunScanMode(self, mode);
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
