//! Loads lint rule severities from `.config/docent.json` (or a custom path).

const std = @import("std");

const RuleSet = @import("RuleSet.zig");
const Severity = @import("Severity.zig");
const ComplexityOptions = @import("ComplexityOptions.zig");

/// Default config path relative to the project root.
pub const default_relative_path = ".config/docent.json";

const RulesJson = struct {
    missing_doc_comment: ?[]const u8 = null,
    missing_doctest: ?[]const u8 = null,
    private_doctest: ?[]const u8 = null,
    blank_doc_comment: ?[]const u8 = null,
    missing_summary_terminal_punctuation: ?[]const u8 = null,
    trailing_blank_doc_comment: ?[]const u8 = null,
    doctest_naming_mismatch: ?[]const u8 = null,
    invalid_leading_phrase: ?[]const u8 = null,
    cognitive_complexity: ?[]const u8 = null,
    identifier_case: ?[]const u8 = null,
};

const ComplexityJson = struct {
    cognitive_threshold: ?u32 = null,
};

const DocentConfigJson = struct {
    rules: ?RulesJson = null,
    complexity: ?ComplexityJson = null,
};

// /// Errors that can occur while loading or parsing configuration.
pub const Error = error{
    ConfigNotFound,
    ConfigParseFailed,
    InvalidConfigPath,
    InvalidSeverity,
    OutOfMemory,
};

/// Walks upward from cwd until `.config/docent.json` exists, or returns null.
pub fn findNearestConfigPath(allocator: std.mem.Allocator, io: std.Io) Error!?[]const u8 {
    return findConfigPathRelative(allocator, io, default_relative_path);
}

/// Walks upward from cwd until `relative_path` exists under a directory, or returns null.
pub fn findConfigPathRelative(allocator: std.mem.Allocator, io: std.Io, relative_path: []const u8) Error!?[]const u8 {
    var current = try realPathFileAlloc(allocator, io, ".");

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, relative_path });
        if (isReadableFile(io, candidate)) {
            allocator.free(current);
            return candidate;
        }
        allocator.free(candidate);

        const parent_opt = std.fs.path.dirname(current);
        if (parent_opt == null) {
            allocator.free(current);
            return null;
        }

        const parent = parent_opt.?;
        if (parent.len == current.len) {
            allocator.free(current);
            return null;
        }

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

/// Loads rule severities from a `docent.json` file; missing `rules` uses `RuleSet` defaults for all fields.
pub fn loadRuleSet(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Error!RuleSet {
    const config_text = readConfigText(allocator, io, config_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigParseFailed,
    };
    defer allocator.free(config_text);

    var parsed = std.json.parseFromSlice(
        DocentConfigJson,
        allocator,
        config_text,
        .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        },
    ) catch return error.ConfigParseFailed;
    defer parsed.deinit();

    const overrides = parsed.value.rules orelse return .{};
    return try mergeRulesJson(.{}, overrides);
}

/// Nearest `.config/docent.json`, or `RuleSet` defaults when no config file exists.
pub fn loadNearestRuleSet(allocator: std.mem.Allocator, io: std.Io) Error!RuleSet {
    return loadRuleSetFromCli(allocator, io, null);
}

/// Loads complexity thresholds from a `docent.json` file; a missing `complexity` section uses defaults.
pub fn loadComplexityOptions(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Error!ComplexityOptions {
    const config_text = readConfigText(allocator, io, config_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigParseFailed,
    };
    defer allocator.free(config_text);

    var parsed = std.json.parseFromSlice(
        DocentConfigJson,
        allocator,
        config_text,
        .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        },
    ) catch return error.ConfigParseFailed;
    defer parsed.deinit();

    var options: ComplexityOptions = .{};
    if (parsed.value.complexity) |complexity| {
        if (complexity.cognitive_threshold) |threshold| options.cognitive_threshold = threshold;
    }
    return options;
}

/// Loads complexity options from an explicit `config_path`, or searches for the default file when null.
pub fn loadComplexityOptionsFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!ComplexityOptions {
    if (config_path) |explicit| {
        const abs = try resolveExplicitConfigPath(allocator, io, explicit);
        defer allocator.free(abs);
        return loadComplexityOptions(allocator, io, abs);
    }
    const discovered = try findNearestConfigPath(allocator, io);
    if (discovered) |path| {
        defer allocator.free(path);
        return loadComplexityOptions(allocator, io, path);
    }
    return .{};
}

/// Loads rules from an explicit `config_path`, or searches for the default file when null.
pub fn loadRuleSetFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!RuleSet {
    if (config_path) |explicit| {
        const abs = try resolveExplicitConfigPath(allocator, io, explicit);
        defer allocator.free(abs);
        return loadRuleSet(allocator, io, abs);
    }
    const discovered = try findNearestConfigPath(allocator, io);
    if (discovered) |path| {
        defer allocator.free(path);
        return loadRuleSet(allocator, io, path);
    }
    return .{};
}

/// Resolved config path for status output: explicit path, discovered file, or null.
pub fn resolveConfigPathForDisplay(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!?[]const u8 {
    if (config_path) |explicit| return try resolveExplicitConfigPath(allocator, io, explicit);
    return findNearestConfigPath(allocator, io);
}

fn resolveExplicitConfigPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Error![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(io, path, &buffer) catch return error.ConfigNotFound;
    return allocator.dupe(u8, buffer[0..len]) catch error.OutOfMemory;
}

fn mergeRulesJson(base: RuleSet, overrides: RulesJson) Error!RuleSet {
    var rs = base;
    inline for (@typeInfo(RulesJson).@"struct".fields) |f| {
        if (@field(overrides, f.name)) |level_name| {
            const level = std.meta.stringToEnum(Severity.Level, level_name) orelse return error.InvalidSeverity;
            setRuleLevel(&rs, f.name, level);
        }
    }
    return rs;
}

fn setRuleLevel(rs: *RuleSet, comptime field: []const u8, level: Severity.Level) void {
    const current = @field(rs.*, field);
    if (current == .forbid and level != .forbid) return;
    @field(rs.*, field) = level;
}

fn realPathFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Error![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(io, path, &buffer) catch return error.OutOfMemory;
    return allocator.dupe(u8, buffer[0..len]) catch error.OutOfMemory;
}

fn isReadableFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn readConfigText(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) ![]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    var reader = file.reader(io, &.{});

    return reader.interface.allocRemaining(allocator, .limited(1 * 1024 * 1024));
}

/// Returns a short human-readable description of `err`.
pub fn formatError(
    err: Error,
) []const u8 {
    return switch (err) {
        error.ConfigNotFound => "config file not found",
        error.ConfigParseFailed => "failed to parse docent.json",
        error.InvalidConfigPath => "invalid config path",
        error.InvalidSeverity => "invalid severity in docent.json (must be allow, warn, deny, or forbid)",
        error.OutOfMemory => "out of memory",
    };
}
