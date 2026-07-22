//! The size namespace gathers size-related rules (line widths, parameter counts, and similar limits).
const scan = @import("../scan.zig");
/// Default scan mode for size rules; `reachability_traversal` because every reachable function is measured, not just the public surface.
pub const default_scan_mode = scan.RuleScanConfig.reachability_traversal;
const category = @import("category.zig");

pub const line_length_limit = @import("size/line_length_limit.zig");
pub const max_fun_params = @import("size/max_fun_params.zig");

/// The `size` configuration: the category-wide scan mode plus each rule's config, decoded generically and resolved in place.
pub const Size = struct {
    /// Category-wide scan mode; rules with a `null` scan mode inherit this value.
    scan_mode: scan.RuleScanConfig = default_scan_mode,
    max_function_parameters: max_fun_params.Rule = .{},
    line_length_limit: line_length_limit.Rule = .{},

    /// Returns the library defaults with scan-mode inheritance already applied.
    pub fn defaults() Size {
        var size: Size = .{};
        size.resolveScanModes();
        return size;
    }

    /// Fills each rule's unset (`null`) scan mode with the category default; call once after decoding.
    pub fn resolveScanModes(self: *Size) void {
        category.resolveScanModes(self);
    }

    /// Overrides every rule's scan mode for a single lint invocation, such as explicit path targets.
    pub fn applyRunScanMode(self: *Size, mode: scan.RuleScanConfig) void {
        category.applyRunScanMode(self, mode);
    }
};
