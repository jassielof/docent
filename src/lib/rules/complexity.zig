//! The complexity namespace gathers complexity-related rules.
const std = @import("std");

const Config = @import("../schemas/Config.zig");
const scanning = @import("../scanning.zig");

/// Default declaration scanning mode for complexity rules.
pub const default_scan_mode = scanning.Modes.reachability_traversal;

pub const cognitive = @import("complexity/cognitive.zig");
pub const cyclomatic = @import("complexity/cyclomatic.zig");
pub const max_fun_params = @import("complexity/max_fun_params.zig");

/// Resolved per-rule options for a complexity lint run.
pub const Options = struct {
    cognitive: cognitive.Options = .{},
    cyclomatic: cyclomatic.Options = .{},
    max_fun_params: max_fun_params.Options = .{},

    pub fn resolve(section: Config.Complexity) Options {
        const category_scan = section.scan_mode orelse default_scan_mode;
        return .{
            .cognitive = cognitive.Options.resolve(category_scan, section.cognitive_complexity),
            .cyclomatic = cyclomatic.Options.resolve(category_scan, section.cyclomatic_complexity),
            .max_fun_params = max_fun_params.Options.resolve(category_scan, section.max_function_parameters),
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
