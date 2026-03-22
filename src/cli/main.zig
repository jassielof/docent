const std = @import("std");
const docent = @import("docent");
const fangz = @import("fangz");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try fangz.App.init(allocator, .{
        .description = "Documentation linter for Zig projects",
    });

    defer app.deinit();

    const root = app.root();

    try root.addPositional(.{
        .name = "paths",
        .description = "Files or directories to lint",
        .variadic = true,
    });

    try root.addFlag(fangz.KeyValueList, .{
        .name = "rule",
        .short = 'r',
        .description = "Override severity: <name>=<allow|warn|deny|forbid>",
        .value_hint = "<rule>=<severity>",
        .allowed_keys = docent.RuleSet.fieldNames(),
        .allowed_values = &.{ "allow", "warn", "deny", "forbid" },
    });

    try root.addFlag(?AllPreset, .{
        .name = "all",
        .description = "The level to apply to all rules.",
    });

    try root.addFlag(OutputMode, .{
        .name = "format",
        .short = 'f',
        .description = "The output format of the lints.",
        .default = .pretty,
    });

    try root.addFlag(bool, .{
        .name = "include-build-scripts",
        .description = "Include build.zig and build/*.zig files in lint targets.",
        .default = false,
    });

    root.hooks.run = &runLint;

    try app.executeProcess();
}

fn runLint(ctx: *fangz.ParseContext) anyerror!void {
    const allocator = ctx.allocator;

    const Args = struct {
        positionals: []const []const u8 = &.{},
        rule: fangz.KeyValueList = &.{},
        all: ?AllPreset = null,
        format: OutputMode = .pretty,
        include_build_scripts: bool = false,
    };

    const args = try ctx.extract(Args);

    var rule_set: docent.RuleSet = .{};

    if (args.all) |preset| rule_set = allPresetToRuleSet(preset);

    for (args.rule) |override| {
        applyRuleOverride(&rule_set, override) catch |err| {
            try printStderr("error: invalid --rule value '{s}={s}': {}\n", .{ override.key, override.value, err });
            std.process.exit(1);
        };
    }

    const targeting_options: docent.targeting.Options = .{
        .include_build_scripts = args.include_build_scripts,
    };

    const path_display_root = try allocPathDisplayRoot(allocator);
    defer allocator.free(path_display_root);

    var summary: docent.output.Summary = .{};
    var all_diagnostics: std.ArrayList(docent.Diagnostic) = .empty;
    defer all_diagnostics.deinit(allocator);

    var manifest_paths: std.ArrayList([]const u8) = .empty;
    defer deinitOwnedPaths(allocator, &manifest_paths);

    const target_paths = if (args.positionals.len > 0)
        args.positionals
    else blk: {
        manifest_paths = loadManifestPaths(allocator) catch |err| {
            try printStderr("error: failed to read manifest 'build.zig.zon': {}\n", .{err});
            std.process.exit(1);
        };
        if (manifest_paths.items.len == 0) {
            try printStderr("error: manifest 'build.zig.zon' has an empty .paths field\n", .{});
            std.process.exit(1);
        }
        break :blk manifest_paths.items;
    };

    for (target_paths) |path| {
        try lintPath(allocator, path, rule_set, targeting_options, &all_diagnostics, &summary, args.format, path_display_root);
    }

    if (args.format == .json) {
        try docent.output.printJsonStdout(allocator, all_diagnostics.items);
    } else {
        try docent.output.printSummaryStderr(summary, docent.output.stderrSummaryOptions("docent", .auto));
    }

    if (summary.errors > 0) {
        std.process.exit(1);
    }
}

// ── Lint orchestration ─────────────────────────────────────────────────────

const OutputMode = enum {
    pretty,
    text,
    minimal,
    json,
};

const AllPreset = enum {
    warn,
    deny,
};

fn lintPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    rule_set: docent.RuleSet,
    targeting_options: docent.targeting.Options,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    output_mode: OutputMode,
    path_display_root: []const u8,
) !void {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        // On some platforms statFile returns IsDir for directory paths
        error.IsDir => {
            try lintDirectory(allocator, path, rule_set, targeting_options, all_diagnostics, summary, output_mode, path_display_root);
            return;
        },
        else => {
            try printStderr("error: cannot access '{s}': {}\n", .{ path, err });
            return;
        },
    };

    if (stat.kind == .directory) {
        try lintDirectory(allocator, path, rule_set, targeting_options, all_diagnostics, summary, output_mode, path_display_root);
    } else {
        if (!std.mem.endsWith(u8, path, ".zig")) return;
        if (docent.targeting.shouldSkipLintFile(path, targeting_options)) return;
        try lintSingleFile(allocator, path, rule_set, all_diagnostics, summary, output_mode, path_display_root);
    }
}

fn loadManifestPaths(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    const manifest_path = try findNearestManifestPath(allocator);
    defer allocator.free(manifest_path);

    const manifest_dir = std.fs.path.dirname(manifest_path) orelse return error.InvalidManifestPath;

    const manifest_text = blk: {
        const file = try std.fs.openFileAbsolute(manifest_path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 1 * 1024 * 1024);
    };
    defer allocator.free(manifest_text);

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer deinitOwnedPaths(allocator, &paths);

    const field_idx = std.mem.indexOf(u8, manifest_text, ".paths") orelse return error.ManifestPathsNotFound;
    var i = field_idx + ".paths".len;

    while (i < manifest_text.len and manifest_text[i] != '{') : (i += 1) {}
    if (i == manifest_text.len) return error.InvalidManifestPaths;

    i += 1;
    var depth: usize = 1;
    while (i < manifest_text.len and depth > 0) {
        if (manifest_text[i] == '/' and i + 1 < manifest_text.len and manifest_text[i + 1] == '/') {
            i += 2;
            while (i < manifest_text.len and manifest_text[i] != '\n') : (i += 1) {}
            continue;
        }

        if (manifest_text[i] == '"') {
            const start = i + 1;
            i += 1;
            var escaped = false;
            while (i < manifest_text.len) : (i += 1) {
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (manifest_text[i] == '\\') {
                    escaped = true;
                    continue;
                }
                if (manifest_text[i] == '"') break;
            }
            if (i >= manifest_text.len) return error.InvalidManifestPaths;

            if (depth == 1) {
                const raw = manifest_text[start..i];
                if (raw.len > 0) {
                    const resolved = if (std.fs.path.isAbsolute(raw))
                        try allocator.dupe(u8, raw)
                    else
                        try std.fs.path.join(allocator, &.{ manifest_dir, raw });
                    try paths.append(allocator, resolved);
                }
            }

            i += 1;
            continue;
        }

        if (manifest_text[i] == '{') {
            depth += 1;
        } else if (manifest_text[i] == '}') {
            depth -= 1;
        }

        i += 1;
    }

    if (depth != 0) return error.InvalidManifestPaths;
    return paths;
}

/// Absolute path of the nearest `build.zig.zon` directory, or canonical cwd if none.
fn allocPathDisplayRoot(allocator: std.mem.Allocator) ![]u8 {
    const manifest = findNearestManifestPath(allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return std.fs.cwd().realpathAlloc(allocator, "."),
    };
    defer allocator.free(manifest);
    const dir = std.fs.path.dirname(manifest) orelse return std.fs.cwd().realpathAlloc(allocator, ".");
    return std.fs.cwd().realpathAlloc(allocator, dir);
}

fn findNearestManifestPath(allocator: std.mem.Allocator) ![]u8 {
    var current = try std.process.getCwdAlloc(allocator);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, "build.zig.zon" });
        if (isReadableFile(candidate)) {
            allocator.free(current);
            return candidate;
        }
        allocator.free(candidate);

        const parent_opt = std.fs.path.dirname(current);
        if (parent_opt == null) {
            allocator.free(current);
            return error.ManifestNotFound;
        }

        const parent = parent_opt.?;
        if (parent.len == current.len) {
            allocator.free(current);
            return error.ManifestNotFound;
        }

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

fn isReadableFile(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn deinitOwnedPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

fn lintDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    rule_set: docent.RuleSet,
    targeting_options: docent.targeting.Options,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    output_mode: OutputMode,
    path_display_root: []const u8,
) !void {
    var targets = try docent.targeting.collectDirectoryLintTargets(allocator, dir_path, targeting_options);
    defer docent.targeting.deinitOwnedPaths(allocator, &targets);

    for (targets.items) |path| {
        try lintSingleFile(allocator, path, rule_set, all_diagnostics, summary, output_mode, path_display_root);
    }
}

fn lintSingleFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    rule_set: docent.RuleSet,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    output_mode: OutputMode,
    path_display_root: []const u8,
) !void {
    var result = docent.lintFile(allocator, path, rule_set) catch |err| {
        try printStderr("error: failed to lint '{s}': {}\n", .{ path, err });
        return;
    };
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        summary.observe(d);

        if (output_mode == .json) {
            try all_diagnostics.append(allocator, d);
        } else {
            try docent.output.printDiagnosticStderr(d, docent.output.stderrTextOptions(textFormat(output_mode), .auto, path_display_root));
        }
    }
}

fn textFormat(mode: OutputMode) docent.output.TextFormat {
    return switch (mode) {
        .pretty, .text => .pretty,
        .minimal => .minimal,
        .json => unreachable,
    };
}

// ── Rule overrides ─────────────────────────────────────────────────────────

/// Builds a `RuleSet` with every field set to the preset severity.
/// The `inline for` unrolls at comptime — adding a field to `RuleSet` is
/// automatically picked up here with no manual update needed.
fn allPresetToRuleSet(preset: AllPreset) docent.RuleSet {
    var rs: docent.RuleSet = .{};
    const sev: docent.Severity = switch (preset) {
        .warn => .warn,
        .deny => .deny,
    };
    inline for (@typeInfo(docent.RuleSet).@"struct".fields) |f| {
        @field(rs, f.name) = sev;
    }
    return rs;
}

/// Applies a single `key=severity` override to the rule set.
/// Uses `std.meta.stringToEnum` for severity parsing and `inline for` for
/// field dispatch — both auto-sync with any future changes to `RuleSet`.
/// Because fangz validates `allowed_keys` at parse time, `error.UnknownRule`
/// here is effectively dead code for values arriving through the CLI.
fn applyRuleOverride(rs: *docent.RuleSet, kv: fangz.KeyValuePair) !void {
    const sev = std.meta.stringToEnum(docent.Severity, kv.value) orelse return error.InvalidSeverity;
    inline for (@typeInfo(docent.RuleSet).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, kv.key)) {
            @field(rs, f.name) = sev;
            return;
        }
    }
    return error.UnknownRule;
}

// ── I/O helpers ────────────────────────────────────────────────────────────

fn printStderr(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    try stderr.interface.print(fmt, args);
    try stderr.interface.flush();
}
