const std = @import("std");

const carnaval = @import("carnaval");
const docent = @import("docent");
const fangz = @import("fangz");

const cli = @import("root_commands.zig");

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
        // TODO: Description should be inferred from the manifest (build.zig.zon)
        .description = "Docent is a documentation linter for Zig projects.",
    });

    defer app.deinit();

    const root = app.root();
    // TODO: There's no need to move all of this out of the main file if it'll be only used here
    try cli.registerDocentRoot(root);
    root.hooks.run = &runLint;

    try app.executeProcess(init.minimal.args);
}

fn runLint(ctx: *fangz.ParseContext) anyerror!void {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const Args = struct {
        positionals: []const []const u8 = &.{},
        rule: fangz.KeyValueList = &.{},
        all: ?cli.AllPreset = null,
        format: cli.OutputMode = .pretty,
        include_build_scripts: bool = false,
        fail_fast: cli.FailFast = .any,
    };

    const args = try ctx.extract(Args);

    var rule_set: docent.RuleSet = .{};

    if (args.all) |preset| rule_set = allPresetToRuleSet(preset);

    for (args.rule) |override| {
        applyRuleOverride(&rule_set, override) catch |err| {
            try printStderr(io, "error: invalid --rule value '{s}={s}': {}\n", .{ override.key, override.value, err });
            std.process.exit(1);
        };
    }

    const targeting_options: docent.targeting.Options = .{
        .include_build_scripts = args.include_build_scripts,
    };

    const path_display_root = try allocPathDisplayRoot(allocator, io);
    defer allocator.free(path_display_root);

    var summary: docent.output.Summary = .{};
    var all_diagnostics: std.ArrayList(docent.Diagnostic) = .empty;
    defer all_diagnostics.deinit(allocator);

    var manifest_paths: std.ArrayList([]const u8) = .empty;
    defer deinitOwnedPaths(allocator, &manifest_paths);

    const target_paths = if (args.positionals.len > 0)
        args.positionals
    else blk: {
        manifest_paths = loadManifestPaths(allocator, io) catch |err| {
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

fn failFastMatches(ff: cli.FailFast, severity: docent.Severity) bool {
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
    output_mode: cli.OutputMode,
    path_display_root: []const u8,
    fail_fast: cli.FailFast,
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
        error.ManifestNotFound => "manifest 'build.zig.zon' not found in current or parent directories",
        error.InvalidManifestPath => "invalid manifest path",
        error.ManifestPathsNotFound => "'.paths' field not found in manifest",
        error.InvalidManifestPaths => "invalid '.paths' field in manifest",
        error.InvalidSeverity => "invalid severity (must be one of allow, warn, deny, forbid)",
        error.UnknownRule => "unknown rule name",
        else => "unknown error",
    };
}

fn loadManifestPaths(allocator: std.mem.Allocator, io: std.Io) !std.ArrayList([]const u8) {
    const manifest_path = try findNearestManifestPath(allocator, io);
    defer allocator.free(manifest_path);

    const manifest_dir = std.fs.path.dirname(manifest_path) orelse return error.InvalidManifestPath;

    const manifest_text = blk: {
        const file = try std.Io.Dir.openFileAbsolute(io, manifest_path, .{});
        defer file.close(io);
        var reader = file.reader(io, &.{});
        break :blk try reader.interface.allocRemaining(allocator, .limited(1 * 1024 * 1024));
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
fn allocPathDisplayRoot(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const manifest = findNearestManifestPath(allocator, io) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return realPathFileAlloc(allocator, io, "."),
    };
    defer allocator.free(manifest);
    const dir = std.fs.path.dirname(manifest) orelse return realPathFileAlloc(allocator, io, ".");
    return realPathFileAlloc(allocator, io, dir);
}

fn findNearestManifestPath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var current = try realPathFileAlloc(allocator, io, ".");

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, "build.zig.zon" });
        if (isReadableFile(io, candidate)) {
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

fn isReadableFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
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

fn deinitOwnedPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

fn lintDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    rule_set: docent.RuleSet,
    targeting_options: docent.targeting.Options,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    output_mode: cli.OutputMode,
    path_display_root: []const u8,
    fail_fast: cli.FailFast,
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
    output_mode: cli.OutputMode,
    path_display_root: []const u8,
    fail_fast: cli.FailFast,
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

fn textFormat(mode: cli.OutputMode) docent.output.TextFormat {
    return switch (mode) {
        .pretty, .text => .pretty,
        .minimal => .minimal,
        .json => unreachable,
    };
}

/// Builds a `RuleSet` with every field set to the preset severity.
/// The `inline for` unrolls at comptime — adding a field to `RuleSet` is
/// automatically picked up here with no manual update needed.
fn allPresetToRuleSet(preset: cli.AllPreset) docent.RuleSet {
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
            const current = @field(rs, f.name);
            if (current == .forbid and sev != .forbid) return;
            @field(rs, f.name) = sev;
            return;
        }
    }
    return error.UnknownRule;
}

fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    try stderr.interface.print(fmt, args);
    try stderr.interface.flush();
}
