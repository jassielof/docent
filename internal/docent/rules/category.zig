//! Shared scan-mode helpers for rule-category config structs.
//!
//! A category struct is a `scan_mode` field (the category default) plus one `Rule` field per rule. These free functions operate generically on any such struct, so each category delegates instead of repeating the field walk.

const std = @import("std");

const scan = @import("../scan.zig");
const severity = @import("../severity.zig");

/// Builds a rule's full config type: a `level` severity, an optional `scan_mode`, and an `options` sub-space.
///
/// `default_severity` seeds `level`, `OptionsType` is the rule's granular knobs, and `default_scan` is the category scan mode applied when `scan_mode` is still `null`. Each rule keeps its own documented `OptionsType`; only this universal envelope is shared.
pub fn Rule(
    comptime default_severity: severity.Level,
    comptime OptionsType: type,
    comptime default_scan: scan.RuleScanConfig,
) type {
    return struct {
        /// Severity at which violations are reported; the TOML key is `level`.
        level: severity.Level = default_severity,
        /// Declarations this rule inspects; `null` inherits the category scan mode.
        scan_mode: ?scan.RuleScanConfig = null,
        /// Granular knobs, read as direct keys under the rule's config table.
        options: OptionsType = .{},

        /// The rule's granular options type.
        pub const Options = OptionsType;

        /// Returns whether checks skip non-public declarations, resolving an unset `scan_mode` to the category default.
        pub fn publicApiOnly(self: @This()) bool {
            return (self.scan_mode orelse default_scan).publicApiOnly();
        }
    };
}

/// Fills each rule's unset (`null`) scan mode with the category default; call once after decoding.
pub fn resolveScanModes(self: anytype) void {
    inline for (std.meta.fields(@TypeOf(self.*))) |field| {
        if (comptime std.mem.eql(
            u8,
            field.name,
            "scan_mode",
        )) continue;
        if (@field(self, field.name).scan_mode == null) {
            @field(self, field.name).scan_mode = self.scan_mode;
        }
    }
}

/// Overrides the category and every rule's scan mode for a single lint invocation, such as explicit path targets.
pub fn applyRunScanMode(self: anytype, mode: scan.RuleScanConfig) void {
    self.scan_mode = mode;
    inline for (std.meta.fields(@TypeOf(self.*))) |field| {
        if (comptime std.mem.eql(
            u8,
            field.name,
            "scan_mode",
        )) continue;
        @field(self, field.name).scan_mode = mode;
    }
}
