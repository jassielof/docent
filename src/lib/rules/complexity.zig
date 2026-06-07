//! The complexity namespace gathers complexity-related rules.
const std = @import("std");
const toml = @import("toml");

const rule_config = @import("config.zig");
const scanning = @import("../scanning.zig");

/// Default declaration scanning mode for complexity rules.
pub const default_scan_mode = scanning.Modes.reachability_traversal;

pub const cognitive = @import("complexity/cognitive.zig");
pub const cyclomatic = @import("complexity/cyclomatic.zig");
pub const max_fun_params = @import("complexity/max_fun_params.zig");

/// Typed `[complexity]` configuration section.
pub const Section = struct {
    scan_mode: ?scanning.Modes = null,
    cognitive_complexity: cognitive.Config = .{},
    cyclomatic_complexity: cyclomatic.Config = .{},
    max_function_parameters: max_fun_params.Config = .{},
};

pub fn decodeSection(section: *const toml.Table) rule_config.Error!Section {
    var complexity: Section = .{};
    if (section.get("scan_mode")) |value| complexity.scan_mode = try rule_config.decodeScanModeValue(value);
    if (section.get("cognitive_complexity")) |value| complexity.cognitive_complexity = try rule_config.decodeRuleThreshold(value);
    if (section.get("cyclomatic_complexity")) |value| complexity.cyclomatic_complexity = try rule_config.decodeRuleThreshold(value);
    if (section.get("max_function_parameters")) |value| complexity.max_function_parameters = try rule_config.decodeRuleThreshold(value);
    return complexity;
}

/// Resolved per-rule options for a complexity lint run.
pub const Options = struct {
    cognitive: cognitive.Options = .{},
    cyclomatic: cyclomatic.Options = .{},
    max_fun_params: max_fun_params.Options = .{},

    pub fn resolve(section: Section) Options {
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
