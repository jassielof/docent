//! Loads lint rule severities from `.config/docent.toml` (or a custom path).

const std = @import("std");

const RuleSeverities = @import("RuleSeverities.zig");
const scanning = @import("scanning.zig");
const rules = @import("rules.zig");
const Config = @import("schemas/Config.zig");

/// Default config path relative to the project root.
pub const default_relative_path = ".config/docent.toml";

/// Errors that can occur while loading or parsing configuration.
pub const Error = Config.Error || error{
    ConfigNotFound,
    InvalidConfigPath,
};

/// Walks upward from cwd until `.config/docent.toml` exists, or returns null.
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

/// Loads and decodes a `docent.toml` file.
pub fn loadConfig(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Error!Config {
    var parsed = try parseConfigFile(allocator, io, config_path);
    defer parsed.deinit();
    return try Config.decode(parsed.root);
}

/// Loads config from an explicit `config_path`, or searches for the default file when null.
pub fn loadConfigFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!Config {
    if (config_path) |explicit| {
        const abs = try resolveExplicitConfigPath(allocator, io, explicit);
        defer allocator.free(abs);
        return loadConfig(allocator, io, abs);
    }
    const discovered = try findNearestConfigPath(allocator, io);
    if (discovered) |path| {
        defer allocator.free(path);
        return loadConfig(allocator, io, path);
    }
    return .{};
}

/// Loads rule severities from a `docent.toml` file; omitted rules keep library defaults.
pub fn loadRuleSeverities(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Error!RuleSeverities {
    const cfg = try loadConfig(allocator, io, config_path);
    var rule_severities: RuleSeverities = .{};
    try Config.applyRuleSeverities(cfg, &rule_severities);
    return rule_severities;
}

/// Nearest `.config/docent.toml`, or library defaults when no config file exists.
pub fn loadNearestRuleSeverities(allocator: std.mem.Allocator, io: std.Io) Error!RuleSeverities {
    return loadRuleSeveritiesFromCli(allocator, io, null);
}

/// Loads resolved documentation rule config from a `docent.toml` file.
pub fn loadDocOptions(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Error!rules.doc.Doc {
    const cfg = try loadConfig(allocator, io, config_path);
    return cfg.doc;
}

/// Loads documentation config from an explicit `config_path`, or searches for the default file when null.
pub fn loadDocOptionsFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!rules.doc.Doc {
    const cfg = try loadConfigFromCli(allocator, io, config_path);
    return cfg.doc;
}

/// Loads resolved complexity rule config from a `docent.toml` file.
pub fn loadComplexityOptions(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Error!rules.complexity.Complexity {
    const cfg = try loadConfig(allocator, io, config_path);
    return cfg.complexity;
}

/// Loads complexity config from an explicit `config_path`, or searches for the default file when null.
pub fn loadComplexityOptionsFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!rules.complexity.Complexity {
    const cfg = try loadConfigFromCli(allocator, io, config_path);
    return cfg.complexity;
}

/// Loads resolved style rule config from a `docent.toml` file.
pub fn loadStyleOptions(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Error!rules.style.Style {
    const cfg = try loadConfig(allocator, io, config_path);
    return cfg.style;
}

/// Loads style config from an explicit `config_path`, or searches for the default file when null.
pub fn loadStyleOptionsFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!rules.style.Style {
    const cfg = try loadConfigFromCli(allocator, io, config_path);
    return cfg.style;
}

/// Returns the declaration scan mode for documentation rules.
pub fn loadDocScanModeFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!scanning.Modes {
    const cfg = try loadConfigFromCli(allocator, io, config_path);
    return cfg.doc.scan_mode;
}

/// Returns the declaration scan mode for complexity rules.
pub fn loadComplexityScanModeFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!scanning.Modes {
    const cfg = try loadConfigFromCli(allocator, io, config_path);
    return cfg.complexity.scan_mode;
}

/// Returns the declaration scan mode for style rules.
pub fn loadStyleScanModeFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!scanning.Modes {
    const cfg = try loadConfigFromCli(allocator, io, config_path);
    return cfg.style.scan_mode;
}

/// Loads rules from an explicit `config_path`, or searches for the default file when null.
pub fn loadRuleSeveritiesFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!RuleSeverities {
    const cfg = try loadConfigFromCli(allocator, io, config_path);
    var rule_severities: RuleSeverities = .{};
    try Config.applyRuleSeverities(cfg, &rule_severities);
    return rule_severities;
}

/// Resolved config path for status output: explicit path, discovered file, or null.
pub fn resolveConfigPathForDisplay(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!?[]const u8 {
    if (config_path) |explicit| return try resolveExplicitConfigPath(allocator, io, explicit);
    return findNearestConfigPath(allocator, io);
}

const ParsedConfig = struct {
    root: @import("toml").DynamicValue,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *ParsedConfig) void {
        self.root.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

fn parseConfigFile(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Error!ParsedConfig {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const config_text = readConfigText(arena.allocator(), io, config_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigParseFailed,
    };

    const root = try Config.parseRoot(arena.allocator(), config_text);
    return .{ .root = root, .arena = arena };
}

fn resolveExplicitConfigPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Error![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(io, path, &buffer) catch return error.ConfigNotFound;
    return allocator.dupe(u8, buffer[0..len]) catch error.OutOfMemory;
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
    return std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(1 * 1024 * 1024));
}

/// Returns a short human-readable description of `err`.
pub fn formatError(
    err: Error,
) []const u8 {
    return switch (err) {
        error.ConfigNotFound => "config file not found",
        error.ConfigParseFailed => "failed to parse docent.toml",
        error.InvalidConfigPath => "invalid config path",
        error.InvalidSeverity => "invalid severity in docent.toml (must be allow, warn, deny, or forbid)",
        error.InvalidScanMode => "invalid scan_mode in docent.toml (must be public or all)",
        error.OutOfMemory => "out of memory",
    };
}
