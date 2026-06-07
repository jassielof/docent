//! The style namespace gathers style-related rules.
const std = @import("std");

const Config = @import("../schemas/Config.zig");
const scan_modes = @import("../scan_modes.zig");

/// Default declaration scanning mode for style rules.
pub const default_scan_mode = scan_modes.Mode.reachability_traversal;

pub const identifier_case = @import("style/identifier_case.zig");

/// Resolved per-rule options for a style lint run.
pub const Options = struct {
    identifier_case: identifier_case.Options = .{},

    pub fn resolve(section: Config.Style) Options {
        const category_scan = section.scan_mode orelse default_scan_mode;
        return .{
            .identifier_case = identifier_case.Options.resolve(category_scan, section.identifier_case),
        };
    }

    pub fn defaults() Options {
        return resolve(.{});
    }

    pub fn applyRunScanMode(self: *Options, mode: scan_modes.Mode) void {
        inline for (std.meta.fields(@This())) |field| {
            @field(self, field.name).scan_mode = mode;
        }
    }
};
