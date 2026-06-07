//! Shared configuration shapes and TOML decode helpers for lint rules.

const std = @import("std");
const toml = @import("toml");

const scanning = @import("../scanning.zig");
const severity = @import("../severity.zig");

pub const Error = error{
    ConfigParseFailed,
    InvalidSeverity,
    InvalidScanMode,
    OutOfMemory,
};

/// Rule with only severity and an optional scan-mode override.
pub const RuleSimple = struct {
    level: ?severity.Level = null,
    scan_mode: ?scanning.Modes = null,
};

/// Threshold rule shared by complexity rules.
pub const RuleThreshold = struct {
    level: ?severity.Level = null,
    scan_mode: ?scanning.Modes = null,
    threshold: ?u32 = null,
};

pub fn decodeRuleSimple(value: toml.DynamicValue) Error!RuleSimple {
    return .{
        .level = try decodeLevelValue(value),
        .scan_mode = decodeScanModeField(value),
    };
}

pub fn decodeRuleThreshold(value: toml.DynamicValue) Error!RuleThreshold {
    return .{
        .level = try decodeLevelValue(value),
        .scan_mode = decodeScanModeField(value),
        .threshold = decodeU32Field(value, "threshold"),
    };
}

pub fn decodeLevelValue(value: toml.DynamicValue) Error!?severity.Level {
    const level_name = std.mem.trim(u8, try ruleLevelName(value), " \t\r\n");
    if (level_name.len == 0) return null;
    return std.meta.stringToEnum(severity.Level, level_name) orelse return error.InvalidSeverity;
}

pub fn decodeScanModeValue(value: toml.DynamicValue) Error!scanning.Modes {
    const mode = value.stringSlice() orelse return error.ConfigParseFailed;
    return scanning.Modes.fromConfigString(mode) orelse return error.InvalidScanMode;
}

pub fn decodeScanModeField(value: toml.DynamicValue) ?scanning.Modes {
    return switch (value) {
        .table => |table| blk: {
            const field_value = table.get("scan_mode") orelse return null;
            const mode = field_value.stringSlice() orelse return null;
            break :blk scanning.Modes.fromConfigString(mode);
        },
        else => null,
    };
}

pub fn decodeU32Field(value: toml.DynamicValue, key: []const u8) ?u32 {
    return switch (value) {
        .table => |table| blk: {
            const field_value = table.get(key) orelse return null;
            break :blk switch (field_value) {
                .integer => |integer_value| std.math.cast(u32, integer_value) orelse null,
                else => null,
            };
        },
        else => null,
    };
}

pub fn decodeBoolField(value: toml.DynamicValue, key: []const u8) ?bool {
    return switch (value) {
        .table => |table| blk: {
            const field_value = table.get(key) orelse return null;
            break :blk switch (field_value) {
                .boolean => |enabled| enabled,
                else => null,
            };
        },
        else => null,
    };
}

pub fn decodeStringField(value: toml.DynamicValue, key: []const u8) ?[]const u8 {
    return switch (value) {
        .table => |table| blk: {
            const field_value = table.get(key) orelse return null;
            break :blk field_value.stringSlice();
        },
        else => null,
    };
}

fn ruleLevelName(value: toml.DynamicValue) Error![]const u8 {
    return switch (value) {
        .string => |string_value| string_value.bytes,
        .table => |table| {
            const level_value = table.get("level") orelse return "";
            return level_value.stringSlice() orelse return error.ConfigParseFailed;
        },
        .boolean, .integer, .float, .array => return "",
        else => return error.ConfigParseFailed,
    };
}
