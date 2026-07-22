//! The style namespace gathers style-related rules.
const scan = @import("../scan.zig");
const category = @import("category.zig");

pub const identifier_case = @import("style/identifier_case.zig");

/// Default scan mode for style rules; `reachability_traversal` because naming and layout apply to every reachable declaration, not just the public surface.
pub const default_scan_mode = scan.RuleScanConfig.reachability_traversal;

/// The `style` configuration: the category-wide scan mode plus each rule's config, decoded generically and resolved in place.
pub const Style = struct {
    /// Category-wide scan mode; rules with a `null` scan mode inherit this value.
    scan_mode: scan.RuleScanConfig = default_scan_mode,
    identifier_case: identifier_case.Rule = .{},

    /// Returns the library defaults with scan-mode inheritance already applied.
    pub fn defaults() Style {
        var style: Style = .{};
        style.resolveScanModes();
        return style;
    }

    /// Fills each rule's unset (`null`) scan mode with the category default; call once after decoding.
    pub fn resolveScanModes(self: *Style) void {
        category.resolveScanModes(self);
    }

    /// Overrides every rule's scan mode for a single lint invocation, such as explicit path targets.
    pub fn applyRunScanMode(self: *Style, mode: scan.RuleScanConfig) void {
        category.applyRunScanMode(self, mode);
    }
};
