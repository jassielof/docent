//! The style namespace gathers style-related rules.
const std = @import("std");
const toml = @import("toml");

const rule_config = @import("config.zig");
const scanning = @import("../scanning.zig");

/// Default declaration scanning mode for style rules.
pub const default_scan_mode = scanning.Modes.reachability_traversal;

pub const identifier_case = @import("style/identifier_case.zig");
pub const line_length_limit = @import("style/line_length_limit.zig");

/// Typed `[style]` configuration section.
pub const Section = struct {
    scan_mode: ?scanning.Modes = null,
    identifier_case: identifier_case.Config = .{},
    line_length_limit: line_length_limit.Config = .{},
};

pub fn decodeSection(section: *const toml.Table) rule_config.Error!Section {
    var style: Section = .{};
    if (section.get("scan_mode")) |value| style.scan_mode = try rule_config.decodeScanModeValue(value);
    if (section.get("identifier_case")) |value| style.identifier_case = try identifier_case.decodeConfig(value);
    if (section.get("line_length_limit")) |value| style.line_length_limit = try line_length_limit.decodeConfig(value);
    return style;
}

/// Resolved per-rule options for a style lint run.
pub const Options = struct {
    identifier_case: identifier_case.Options = .{},
    line_length_limit: line_length_limit.Options = .{},

    pub fn resolve(section: Section) Options {
        const category_scan = section.scan_mode orelse default_scan_mode;
        return .{
            .identifier_case = identifier_case.Options.resolve(category_scan, section.identifier_case),
            .line_length_limit = line_length_limit.Options.resolve(category_scan, section.line_length_limit),
        };
    }

    pub fn defaults() Options {
        return resolve(.{});
    }

    pub fn applyRunScanMode(self: *Options, mode: scanning.Modes) void {
        inline for (std.meta.fields(@This())) |field| {
            @field(self, field.name).scan_mode = mode;
        }
    }
};
