//! The style namespace gathers style-related rules.
const std = @import("std");

const Config = @import("../schemas/Config.zig");
const scanning = @import("../scanning.zig");

/// Default declaration scanning mode for style rules.
pub const default_scan_mode = scanning.Modes.reachability_traversal;

pub const identifier_case = @import("style/identifier_case.zig");
pub const line_length_limit = @import("style/line_length_limit.zig");

/// Resolved per-rule options for a style lint run.
pub const Options = struct {
    identifier_case: identifier_case.Options = .{},
    line_length_limit: line_length_limit.Options = .{},

    pub fn resolve(section: Config.Style) Options {
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
