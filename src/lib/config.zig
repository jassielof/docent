//! Loads lint rule severities from `.config/docent.toml` (or a custom path).

const std = @import("std");

const RuleSet = @import("RuleSet.zig");
const ComplexityOptions = @import("ComplexityOptions.zig");
const DocsOptions = @import("DocsOptions.zig");
const ConfigToml = @import("ConfigToml.zig");

/// Default config path relative to the project root.
pub const default_relative_path = ".config/docent.toml";

/// Errors that can occur while loading or parsing configuration.
pub const Error = ConfigToml.Error || error{
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

/// Loads rule severities from a `docent.toml` file; omitted rules keep `RuleSet` defaults.
pub fn loadRuleSet(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Error!RuleSet {
    var parsed = try parseConfigFile(allocator, io, config_path);
    defer parsed.deinit();

    var rule_set: RuleSet = .{};
    try ConfigToml.applyRuleSet(parsed.root, &rule_set);
    return rule_set;
}

/// Nearest `.config/docent.toml`, or `RuleSet` defaults when no config file exists.
pub fn loadNearestRuleSet(allocator: std.mem.Allocator, io: std.Io) Error!RuleSet {
    return loadRuleSetFromCli(allocator, io, null);
}

/// Loads documentation rule options from a `docent.toml` file; a missing `[docs]` section uses defaults.
pub fn loadDocsOptions(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Error!DocsOptions {
    var parsed = try parseConfigFile(allocator, io, config_path);
    defer parsed.deinit();

    var options: DocsOptions = .{};
    try ConfigToml.applyDocsOptions(parsed.root, &options);
    return options;
}

/// Loads documentation options from an explicit `config_path`, or searches for the default file when null.
pub fn loadDocsOptionsFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!DocsOptions {
    if (config_path) |explicit| {
        const abs = try resolveExplicitConfigPath(allocator, io, explicit);
        defer allocator.free(abs);
        return loadDocsOptions(allocator, io, abs);
    }
    const discovered = try findNearestConfigPath(allocator, io);
    if (discovered) |path| {
        defer allocator.free(path);
        return loadDocsOptions(allocator, io, path);
    }
    return .{};
}

/// Loads complexity thresholds from a `docent.toml` file; a missing `[complexity]` section uses defaults.
pub fn loadComplexityOptions(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Error!ComplexityOptions {
    var parsed = try parseConfigFile(allocator, io, config_path);
    defer parsed.deinit();

    var options: ComplexityOptions = .{};
    try ConfigToml.applyComplexityOptions(parsed.root, &options);
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

/// Returns whether doc lint should restrict checks to public declarations.
pub fn loadDocsPublicApiOnlyFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!bool {
    return loadScanModeFromCli(allocator, io, config_path, ConfigToml.docsPublicApiOnly, true);
}

/// Returns whether complexity lint should restrict checks to public declarations.
pub fn loadComplexityPublicApiOnlyFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!bool {
    return loadScanModeFromCli(allocator, io, config_path, ConfigToml.complexityPublicApiOnly, false);
}

/// Returns whether style lint should restrict checks to public declarations.
pub fn loadStylePublicApiOnlyFromCli(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) Error!bool {
    return loadScanModeFromCli(allocator, io, config_path, ConfigToml.stylePublicApiOnly, false);
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

    const root = try ConfigToml.parseRoot(arena.allocator(), config_text);
    return .{ .root = root, .arena = arena };
}

fn loadScanModeFromCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
    comptime reader: *const fn (@import("toml").DynamicValue) ConfigToml.Error!bool,
    comptime default_value: bool,
) Error!bool {
    if (config_path) |explicit| {
        const abs = try resolveExplicitConfigPath(allocator, io, explicit);
        defer allocator.free(abs);
        var parsed = try parseConfigFile(allocator, io, abs);
        defer parsed.deinit();
        return try reader(parsed.root);
    }
    const discovered = try findNearestConfigPath(allocator, io);
    if (discovered) |path| {
        defer allocator.free(path);
        var parsed = try parseConfigFile(allocator, io, path);
        defer parsed.deinit();
        return try reader(parsed.root);
    }
    return default_value;
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
        error.OutOfMemory => "out of memory",
    };
}
