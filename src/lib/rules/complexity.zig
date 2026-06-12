//! The complexity namespace gathers complexity-related rules.
const scanning = @import("../scanning.zig");
const category = @import("category.zig");

/// Default scan mode for complexity rules; `reachability_traversal` because every reachable function is measured, not just the public surface.
pub const default_scan_mode = scanning.Modes.reachability_traversal;

pub const cognitive = @import("complexity/cognitive.zig");
pub const cyclomatic = @import("complexity/cyclomatic.zig");
pub const max_fun_params = @import("complexity/max_fun_params.zig");

/// The `complexity` configuration: the category-wide scan mode plus each rule's config, decoded generically and resolved in place.
pub const Complexity = struct {
    /// Category-wide scan mode; rules with a `null` scan mode inherit this value.
    scan_mode: scanning.Modes = default_scan_mode,
    cognitive_complexity: cognitive.Rule = .{},
    cyclomatic_complexity: cyclomatic.Rule = .{},
    max_function_parameters: max_fun_params.Rule = .{},

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
    pub fn applyRunScanMode(self: *Complexity, mode: scanning.Modes) void {
        category.applyRunScanMode(self, mode);
    }
};
