//! Loads lint rule severities from `.config/docent.toml` (or a custom path).

const std = @import("std");

const rules_mod = @import("rules");
const rules = rules_mod;
const RuleSeverities = rules_mod.RuleSeverities;
const scan = rules_mod.scan;

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
    return findConfigPathRelative(
        allocator,
        io,
        default_relative_path,
    );
}

/// Walks upward from cwd until `relative_path` exists under a directory, or returns null.
pub fn findConfigPathRelative(
    allocator: std.mem.Allocator,
    io: std.Io,
    relative_path: []const u8,
) Error!?[]const u8 {
    var current = try realPathFileAlloc(
        allocator,
        io,
        ".",
    );

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
///
/// Caller owns path lists under `fmt` and `check`; free with `Config.deinit`.
pub fn loadConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
) Error!Config {
    var parsed = try parseConfigFile(
        allocator,
        io,
        config_path,
    );
    defer parsed.deinit();
    var cfg = try Config.decode(allocator, parsed.root);
    errdefer cfg.deinit(allocator);
    try resolveConfigRelativePaths(
        allocator,
        &cfg,
        config_path,
    );
    return cfg;
}

/// Root directory `include` / `exclude` entries are resolved against: the
/// parent of the directory holding `config_path` (i.e. the directory above
/// `.config/`, for the conventional `.config/docent.toml` layout). This
/// keeps `[fmt].include = ["lib/"]` meaning the same directory regardless of
/// the invoking process's cwd -- e.g. when `zig build` runs the CLI with an
/// inherited cwd that isn't the project root.
fn configRootDir(config_path: []const u8) []const u8 {
    const config_dir = std.fs.path.dirname(config_path) orelse return config_path;
    return std.fs.path.dirname(config_dir) orelse config_dir;
}

fn resolveConfigRelativePaths(
    allocator: std.mem.Allocator,
    cfg: *Config,
    config_path: []const u8,
) Error!void {
    const root_dir = configRootDir(config_path);
    try resolvePathList(
        allocator,
        root_dir,
        &cfg.fmt.include,
    );
    try resolvePathList(
        allocator,
        root_dir,
        &cfg.fmt.exclude,
    );
    try resolvePathList(
        allocator,
        root_dir,
        &cfg.check.include,
    );
    try resolvePathList(
        allocator,
        root_dir,
        &cfg.check.exclude,
    );
}

fn resolvePathList(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    list: *[]const []const u8,
) Error!void {
    if (list.len == 0) return;

    const resolved_list = try allocator.alloc([]const u8, list.len);
    errdefer allocator.free(resolved_list);

    for (list.*, 0..) |entry, i| {
        if (std.fs.path.isAbsolute(entry)) {
            resolved_list[i] = entry;
        } else {
            resolved_list[i] = try std.fs.path.join(allocator, &.{ root_dir, entry });
            allocator.free(entry);
        }
    }

    allocator.free(list.*);
    list.* = resolved_list;
}

/// Loads config from an explicit `config_path`, or searches for the default file when null.
///
/// Caller owns path lists under `fmt` and `check`; free with `Config.deinit`.
pub fn loadConfigFromCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
) Error!Config {
    if (config_path) |explicit| {
        const abs = try resolveExplicitConfigPath(
            allocator,
            io,
            explicit,
        );
        defer allocator.free(abs);
        return loadConfig(
            allocator,
            io,
            abs,
        );
    }
    const discovered = try findNearestConfigPath(allocator, io);
    if (discovered) |path| {
        defer allocator.free(path);
        return loadConfig(
            allocator,
            io,
            path,
        );
    }
    return .{};
}

/// Loads rule severities from a `docent.toml` file; omitted rules keep library defaults.
pub fn loadRuleSeverities(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
) Error!RuleSeverities {
    var cfg = try loadConfig(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    var rule_severities: RuleSeverities = .{};
    try Config.applyRuleSeverities(cfg, &rule_severities);
    return rule_severities;
}

/// Nearest `.config/docent.toml`, or library defaults when no config file exists.
pub fn loadNearestRuleSeverities(allocator: std.mem.Allocator, io: std.Io) Error!RuleSeverities {
    return loadRuleSeveritiesFromCli(
        allocator,
        io,
        null,
    );
}

/// Loads resolved documentation rule config from a `docent.toml` file.
pub fn loadDocOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
) Error!rules.doc.Doc {
    var cfg = try loadConfig(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    return cfg.doc;
}

/// Loads documentation config from an explicit `config_path`, or searches for the default file when null.
pub fn loadDocOptionsFromCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
) Error!rules.doc.Doc {
    var cfg = try loadConfigFromCli(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    return cfg.doc;
}

/// Loads fmt options from an explicit `config_path`, or searches for the default file when null.
///
/// Caller owns `include` / `exclude` path lists; free with `Config.Fmt.deinit`.
pub fn loadFmtOptionsFromCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
) Error!Config.Fmt {
    var cfg = try loadConfigFromCli(
        allocator,
        io,
        config_path,
    );
    const fmt = cfg.fmt;
    cfg.fmt.include = &.{};
    cfg.fmt.exclude = &.{};
    cfg.deinit(allocator);
    return fmt;
}

/// Loads resolved complexity rule config from a `docent.toml` file.
pub fn loadComplexityOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
) Error!rules.complexity.Complexity {
    var cfg = try loadConfig(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    return cfg.complexity;
}

/// Loads complexity config from an explicit `config_path`, or searches for the default file when null.
pub fn loadComplexityOptionsFromCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
) Error!rules.complexity.Complexity {
    var cfg = try loadConfigFromCli(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    return cfg.complexity;
}

/// Loads resolved size rule config from a `docent.toml` file.
pub fn loadSizeOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
) Error!rules.size.Size {
    var cfg = try loadConfig(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    return cfg.size;
}

/// Loads size config from an explicit `config_path`, or searches for the default file when null.
pub fn loadSizeOptionsFromCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
) Error!rules.size.Size {
    var cfg = try loadConfigFromCli(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    return cfg.size;
}

/// Loads resolved style rule config from a `docent.toml` file.
pub fn loadStyleOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
) Error!rules.style.Style {
    var cfg = try loadConfig(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    return cfg.style;
}

/// Loads style config from an explicit `config_path`, or searches for the default file when null.
pub fn loadStyleOptionsFromCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
) Error!rules.style.Style {
    var cfg = try loadConfigFromCli(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    return cfg.style;
}

/// Returns the declaration scan mode for documentation rules.
pub fn loadDocScanModeFromCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
) Error!scan.RuleScanConfig {
    var cfg = try loadConfigFromCli(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    return cfg.doc.scan_mode;
}

/// Returns the declaration scan mode for complexity rules.
pub fn loadComplexityScanModeFromCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
) Error!scan.RuleScanConfig {
    var cfg = try loadConfigFromCli(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    return cfg.complexity.scan_mode;
}

/// Returns the declaration scan mode for size rules.
pub fn loadSizeScanModeFromCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
) Error!scan.RuleScanConfig {
    var cfg = try loadConfigFromCli(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    return cfg.size.scan_mode;
}

/// Returns the declaration scan mode for style rules.
pub fn loadStyleScanModeFromCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
) Error!scan.RuleScanConfig {
    var cfg = try loadConfigFromCli(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    return cfg.style.scan_mode;
}

/// Loads rules from an explicit `config_path`, or searches for the default file when null.
pub fn loadRuleSeveritiesFromCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
) Error!RuleSeverities {
    var cfg = try loadConfigFromCli(
        allocator,
        io,
        config_path,
    );
    defer cfg.deinit(allocator);
    var rule_severities: RuleSeverities = .{};
    try Config.applyRuleSeverities(cfg, &rule_severities);
    return rule_severities;
}

/// Resolved config path for status output: explicit path, discovered file, or null.
pub fn resolveConfigPathForDisplay(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
) Error!?[]const u8 {
    if (config_path) |explicit| return try resolveExplicitConfigPath(
        allocator,
        io,
        explicit,
    );
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

fn parseConfigFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
) Error!ParsedConfig {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const config_text = readConfigText(
        arena.allocator(),
        io,
        config_path,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigParseFailed,
    };

    const root = try Config.parseRoot(arena.allocator(), config_text);
    return .{ .root = root, .arena = arena };
}

fn resolveExplicitConfigPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) Error![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(
        io,
        path,
        &buffer,
    ) catch return error.ConfigNotFound;
    return allocator.dupe(u8, buffer[0..len]) catch error.OutOfMemory;
}

fn realPathFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) Error![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(
        io,
        path,
        &buffer,
    ) catch return error.OutOfMemory;
    return allocator.dupe(u8, buffer[0..len]) catch error.OutOfMemory;
}

fn isReadableFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(
        io,
        path,
        .{},
    ) catch return false;
    file.close(io);
    return true;
}

fn readConfigText(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        config_path,
        allocator,
        .limited(1 * 1024 * 1024),
    );
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
        error.InvalidScanMode => "invalid scan_mode in docent.toml (must be public or all; both apply to the module reachability graph, not a filesystem orphan walk)",
        error.OutOfMemory => "out of memory",
    };
}
