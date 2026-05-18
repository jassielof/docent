const std = @import("std");

const carnaval = @import("carnaval");
const docent = @import("docent");
const fangz = @import("fangz");

const rules_command = @import("commands/rules.zig");
const status_command = @import("commands/status.zig");
pub const rule_config = @import("rule_config.zig");

/// For `tests/cli_ux.zig`; forwards to `commands/rules.zig`.
pub const registerRulesSubcommands = rules_command.register;
pub const registerStatusSubcommand = status_command.register;
pub const rule_flag_examples = rules_command.flag_examples;

fn keyMeta(comptime i: usize) fangz.Command.KeyValueKeyMeta {
    const row = docent.rule_metadata.rules[i];
    return .{
        .name = row.name,
        .default_value = row.default_level,
        .summary = row.summary,
        .description = row.long,
    };
}

fn valueMeta(comptime i: usize) fangz.Command.KeyValueValueMeta {
    const row = docent.rule_metadata.levels[i];
    return .{ .name = row.name, .summary = row.summary };
}

const key_value_keys_storage: [docent.rule_metadata.rules.len]fangz.Command.KeyValueKeyMeta = blk: {
    var a: [docent.rule_metadata.rules.len]fangz.Command.KeyValueKeyMeta = undefined;
    for (0..docent.rule_metadata.rules.len) |i| {
        a[i] = keyMeta(i);
    }
    break :blk a;
};

const key_value_values_storage: [docent.rule_metadata.levels.len]fangz.Command.KeyValueValueMeta = blk: {
    var a: [docent.rule_metadata.levels.len]fangz.Command.KeyValueValueMeta = undefined;
    for (0..docent.rule_metadata.levels.len) |i| {
        a[i] = valueMeta(i);
    }
    break :blk a;
};

const key_value_keys: []const fangz.Command.KeyValueKeyMeta = &key_value_keys_storage;

const key_value_values: []const fangz.Command.KeyValueValueMeta = &key_value_values_storage;

pub const app_examples: []const fangz.Command.CliExample = &.{
    .{ .description = "", .command = "docent src" },
    .{ .description = "", .command = "docent --rule missing_doc_comment=deny src" },
    .{ .description = "", .command = "docent --all deny --rule missing_doctest=allow src" },
    .{ .description = "", .command = "docent docs --output-dir docs" },
    .{ .description = "", .command = "docent completion nu" },
};

pub const key_value_help: fangz.Command.KeyValueHelp = .{
    .keys = key_value_keys,
    .values = key_value_values,
    .override_behavior_note = docent.rule_metadata.override_behavior_note,
    .examples = rules_command.flag_examples,
};

pub const key_value_rule_count = key_value_keys.len;
pub const key_value_level_count = key_value_values.len;

pub const OutputMode = enum {
    pretty,
    text,
    minimal,
    json,
};

pub const AllPreset = rule_config.AllPreset;

pub const FailFast = enum {
    none,
    @"error",
    warn,
    any,
};

fn realPathFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var app = try fangz.App.init(gpa, io, .{
        .display_name = "Docent",
        .author_name = "",
        .author_email = "",
        .tagline = "A Documentation Linter for Zig Projects",
    });

    defer app.deinit();

    const root = app.root();

    try root.addPositional(.{
        .name = "paths",
        .brief = "Files or directories to lint. If omitted, Docent uses package paths from build.zig.zon when available.",
        .variadic = true,
    });

    try root.addFlag(fangz.KeyValueList, .{
        .name = "rule",
        .short = 'r',
        .brief = "Override one rule severity.",
        .description =
        \\You can repeat the flag to override multiple rules.
        \\Run `docent rules` to see rules and defaults.
        ,
        .key_metavar = "RULE",
        .value_metavar = "LEVEL",
        .allowed_keys = docent.RuleSet.fieldNames(),
        .allowed_values = &.{ "allow", "warn", "deny", "forbid" },
        .key_value_help = &key_value_help,
        .examples = rules_command.flag_examples,
        .allowed_values_style = .bullet_list,
    });

    try root.addFlag(?AllPreset, .{
        .name = "all",
        .brief = "Apply one severity to all rules",
        .value_hint = "LEVEL",
    });

    try root.addFlag(OutputMode, .{
        .name = "format",
        .short = 'f',
        .brief = "Output format",
        .value_hint = "FORMAT",
        .default = .pretty,
        .allowed_values_style = .comma,
    });

    try root.addFlag(bool, .{
        .name = "include-build-scripts",
        .brief = "Include build.zig and build/*.zig files in lint targets",
        .default = false,
    });

    try root.addFlag(bool, .{
        .name = "lint-dependencies",
        .brief = "Also lint files under path dependencies from build.zig.zon",
        .default = false,
    });

    try root.addFlag(FailFast, .{
        .name = "fail-fast",
        .short = 'F',
        .brief = "Stop after the first matching severity",
        .value_hint = "WHEN",
        // TODO: This should be using an enum value, not a manual enum literal
        // TODO: It should default to none, not any.
        .default = .any,
    });

    root.examples = app_examples;

    try rules_command.register(root);
    try status_command.register(root, &key_value_help);

    root.hooks.run = &runLint;

    try app.executeProcess(init.minimal.args);
}

fn runLint(ctx: *fangz.ParseContext) anyerror!void {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const Args = struct {
        positionals: []const []const u8 = &.{},
        rule: fangz.KeyValueList = &.{},
        all: ?AllPreset = null,
        format: OutputMode = .pretty,
        include_build_scripts: bool = false,
        lint_dependencies: bool = false,
        fail_fast: FailFast = .any,
    };

    const args = try ctx.extract(Args);

    var rule_set: docent.RuleSet = .{};

    if (args.all) |preset| rule_set = rule_config.allPresetToRuleSet(preset);

    for (args.rule) |override| {
        rule_config.applyRuleOverride(&rule_set, override) catch |err| {
            try printStderr(io, "error: invalid --rule value '{s}={s}': {s}\n", .{
                override.key,
                override.value,
                rule_config.formatRuleConfigError(err),
            });
            std.process.exit(1);
        };
    }

    var exclude_roots: std.ArrayList([]const u8) = .empty;
    defer docent.manifest.deinitOwnedPaths(allocator, &exclude_roots);

    if (docent.manifest.findNearestManifestPath(allocator, io)) |manifest_path| {
        exclude_roots = docent.manifest.loadDependencyPathRoots(allocator, io, manifest_path) catch .empty;
        allocator.free(manifest_path);
    } else |_| {}

    const targeting_options: docent.targeting.Options = .{
        .include_build_scripts = args.include_build_scripts,
        .lint_dependencies = args.lint_dependencies,
        .exclude_roots = exclude_roots.items,
    };

    const path_display_root = try allocPathDisplayRoot(allocator, io);
    defer allocator.free(path_display_root);

    var summary: docent.output.Summary = .{};
    var all_diagnostics: std.ArrayList(docent.Diagnostic) = .empty;
    defer all_diagnostics.deinit(allocator);

    var manifest_paths: std.ArrayList([]const u8) = .empty;
    defer docent.manifest.deinitOwnedPaths(allocator, &manifest_paths);

    const target_paths = if (args.positionals.len > 0)
        args.positionals
    else blk: {
        manifest_paths = docent.manifest.loadNearestPackagePaths(allocator, io) catch |err| {
            try printStderr(io, "error: failed to read manifest 'build.zig.zon': {}\n", .{err});
            std.process.exit(1);
        };
        if (manifest_paths.items.len == 0) {
            try printStderr(io, "error: manifest 'build.zig.zon' has an empty .paths field\n", .{});
            std.process.exit(1);
        }
        break :blk manifest_paths.items;
    };

    for (target_paths) |path| {
        if (try lintPath(allocator, io, path, rule_set, targeting_options, &all_diagnostics, &summary, args.format, path_display_root, args.fail_fast)) {
            break;
        }
    }

    if (args.format == .json) {
        try docent.output.printJsonStdout(io, allocator, all_diagnostics.items);
    } else {
        try docent.output.printSummaryStderr(io, summary, docent.output.stderrSummaryOptions(io, "docent", .auto));
    }

    if (summary.errors > 0) {
        std.process.exit(1);
    }
}

fn failFastMatches(ff: FailFast, severity: docent.Severity) bool {
    return switch (ff) {
        .none => false,
        .@"error" => severity.isError(),
        .warn => severity == .warn,
        .any => severity == .warn or severity.isError(),
    };
}

fn lintPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rule_set: docent.RuleSet,
    targeting_options: docent.targeting.Options,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    output_mode: OutputMode,
    path_display_root: []const u8,
    fail_fast: FailFast,
) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        // On some platforms statFile returns IsDir for directory paths
        error.IsDir => {
            return try lintDirectory(allocator, io, path, rule_set, targeting_options, all_diagnostics, summary, output_mode, path_display_root, fail_fast);
        },
        else => {
            try printAccessError(io, path, err);
            return false;
        },
    };

    if (stat.kind == .directory) {
        return try lintDirectory(allocator, io, path, rule_set, targeting_options, all_diagnostics, summary, output_mode, path_display_root, fail_fast);
    } else {
        if (!std.mem.endsWith(u8, path, ".zig")) return false;
        if (docent.targeting.shouldSkipLintFile(path, targeting_options)) return false;
        return try lintSingleFile(allocator, io, path, rule_set, all_diagnostics, summary, output_mode, path_display_root, fail_fast);
    }
}

// Format the error type to a prettier message
fn formatError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "file not found",
        docent.manifest.Error.ManifestNotFound => "manifest 'build.zig.zon' not found in current or parent directories",
        docent.manifest.Error.InvalidManifestPath => "invalid manifest path",
        docent.manifest.Error.ManifestPathsNotFound => "'.paths' field not found in manifest",
        error.InvalidSeverity => rule_config.formatRuleConfigError(error.InvalidSeverity),
        error.UnknownRule => rule_config.formatRuleConfigError(error.UnknownRule),
        else => "unknown error",
    };
}

/// Absolute path of the nearest `build.zig.zon` directory, or canonical cwd if none.
fn allocPathDisplayRoot(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const manifest = docent.manifest.findNearestManifestPath(allocator, io) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return realPathFileAlloc(allocator, io, "."),
    };
    defer allocator.free(manifest);
    const dir = std.fs.path.dirname(manifest) orelse return realPathFileAlloc(allocator, io, ".");
    return realPathFileAlloc(allocator, io, dir);
}

fn printAccessError(io: std.Io, path: []const u8, err: anyerror) !void {
    const profile = carnaval.colorProfileForHandle(std.Io.File.stderr().handle);
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    const writer = &stderr.interface;

    try carnaval.Style.init().fg(.{ .ansi16 = .red }).bolded().renderWithProfile("error", writer, profile);
    try writer.print(" ({s}): Docent cannot access ", .{formatError(err)});
    try carnaval.Style.init().underlined().renderWithProfile(path, writer, profile);
    try writer.print(".\n", .{});
    try writer.flush();
}

fn lintDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    rule_set: docent.RuleSet,
    targeting_options: docent.targeting.Options,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    output_mode: OutputMode,
    path_display_root: []const u8,
    fail_fast: FailFast,
) !bool {
    var targets = try docent.targeting.collectDirectoryLintTargets(allocator, io, dir_path, targeting_options);
    defer docent.targeting.deinitOwnedPaths(allocator, &targets);

    for (targets.items) |path| {
        if (try lintSingleFile(allocator, io, path, rule_set, all_diagnostics, summary, output_mode, path_display_root, fail_fast)) {
            return true;
        }
    }

    return false;
}

fn lintSingleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rule_set: docent.RuleSet,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    output_mode: OutputMode,
    path_display_root: []const u8,
    fail_fast: FailFast,
) !bool {
    var result = docent.lintFile(allocator, io, path, rule_set) catch |err| {
        try printStderr(io, "error: failed to lint '{s}': {}\n", .{ path, err });
        return false;
    };
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        summary.observe(d);

        if (output_mode == .json) {
            try all_diagnostics.append(allocator, d);
        } else {
            try docent.output.printDiagnosticStderr(io, d, docent.output.stderrTextOptions(io, textFormat(output_mode), .auto, path_display_root));
        }

        if (failFastMatches(fail_fast, d.severity)) return true;
    }

    return false;
}

fn textFormat(mode: OutputMode) docent.output.TextFormat {
    return switch (mode) {
        .pretty, .text => .pretty,
        .minimal => .minimal,
        .json => unreachable,
    };
}

fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    try stderr.interface.print(fmt, args);
    try stderr.interface.flush();
}
