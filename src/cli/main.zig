const std = @import("std");

const carnaval = @import("carnaval");
const docent = @import("docent");
const fangz = @import("fangz");

const status_command = @import("commands/status.zig");
const complexity_command = @import("commands/complexity.zig");
const cli_flags = @import("flags.zig");
pub const rule_config = @import("rule_config.zig");

pub const registerStatusSubcommand = status_command.register;
pub const registerConfigPathFlag = @import("flags.zig").registerConfigPath;

pub const app_examples: []const fangz.Command.CliExample = &.{
    .{ .description = "", .command = "docent src" },
    .{ .description = "", .command = "docent status" },
    .{ .description = "", .command = "docent complexity --threshold 15" },
    .{ .description = "", .command = "docent docs --output-dir docs" },
    .{ .description = "", .command = "docent completion nu" },
};

pub const OutputMode = enum {
    pretty,
    minimal,
    json,
};

pub const FailFast = enum {
    none,
    @"error",
    warn,
    any,
};

/// The default `--fail-fast` behavior is to not fail fast.
pub const default_fail_fast = FailFast.none;

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
        .brief = "Files or directories to lint. Omitted: discover targets from build.zig. One path: module root (public API). Two or more: all .zig files recursively (every declaration).",
        .variadic = true,
    });

    try cli_flags.registerConfigPath(root);

    try root.addFlag(OutputMode, .{
        .name = "format",
        .short = 'f',
        .brief = "Output format",
        .value_hint = "FORMAT",
        .default = .pretty,
        .allowed_values_style = .comma,
    });

    try root.addFlag(bool, .{
        .name = "lib",
        .brief = "Lint library targets only (default)",
        .default = false,
    });

    try root.addFlag(bool, .{
        .name = "bins",
        .brief = "Lint all binary targets",
        .default = false,
    });

    try root.addFlag([]const []const u8, .{
        .name = "bin",
        .brief = "Lint specific binary by name (repeatable)",
    });

    try root.addFlag(bool, .{
        .name = "tests",
        .brief = "Lint all test targets",
        .default = false,
    });

    try root.addFlag([]const []const u8, .{
        .name = "test",
        .brief = "Lint specific test by name (repeatable)",
    });

    try root.addFlag(bool, .{
        .name = "deps",
        .brief = "Also lint files under path dependencies from build.zig.zon",
        .default = false,
    });

    try root.addFlag(bool, .{
        .name = "build-script",
        .brief = "Include build.zig and build/*.zig files in lint targets",
        .default = false,
    });

    try root.addFlag(FailFast, .{
        .name = "fail-fast",
        .short = 'F',
        .brief = "Stop after the first matching severity",
        .value_hint = "WHEN",
        .default = default_fail_fast,
    });

    root.examples = app_examples;

    try status_command.register(root);
    try complexity_command.register(root);

    root.hooks.run = &runLint;

    try app.executeProcess(init.minimal.args);
}

fn runLint(ctx: *fangz.ParseContext) anyerror!void {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const Args = struct {
        positionals: []const []const u8 = &.{},
        config_path: ?[]const u8 = null,
        format: OutputMode = .pretty,
        lib: bool = false,
        bins: bool = false,
        bin: []const []const u8 = &.{},
        tests: bool = false,
        @"test": []const []const u8 = &.{},
        deps: bool = false,
        build_script: bool = false,
        fail_fast: FailFast = default_fail_fast,
    };

    const args = try ctx.extract(Args);

    const rule_set = docent.config.loadRuleSetFromCli(allocator, io, args.config_path) catch |err| {
        try printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    var plan = docent.status_plan.gather(allocator, io, .{
        .lib = args.lib,
        .bins = args.bins,
        .bin_names = args.bin,
        .tests = args.tests,
        .test_names = args.@"test",
        .deps = args.deps,
        .build_script = args.build_script,
        .positionals = args.positionals,
    }) catch |err| {
        try printStderr(io, "error: failed to build lint plan: {}\n", .{err});
        std.process.exit(1);
    };
    defer plan.deinit(allocator);

    const path_display_root = try allocPathDisplayRoot(allocator, io);
    defer allocator.free(path_display_root);

    var summary: docent.output.Summary = .{};
    var all_diagnostics: std.ArrayList(docent.Diagnostic) = .empty;
    defer {
        for (all_diagnostics.items) |d| docent.Diagnostic.deinitAlloc(d, allocator);
        all_diagnostics.deinit(allocator);
    }

    var linted_files = std.StringHashMap(void).init(allocator);
    defer linted_files.deinit();

    var should_stop = false;

    const library_entry_roots_owned = blk: {
        if (plan.path_mode == .recursive) break :blk &.{};
        if (plan.path_mode == .module_root) break :blk plan.module_entry_roots;
        const roots = docent.collectLibraryEntryRoots(allocator, io, plan.package.project_root) catch &.{};
        break :blk roots;
    };
    defer if (plan.path_mode == .project) {
        for (library_entry_roots_owned) |root_path| allocator.free(root_path);
        allocator.free(library_entry_roots_owned);
    };

    const lint_options: docent.LintOptions = switch (plan.path_mode) {
        .project => .{
            .module_name = plan.package.name,
            .public_api_only = true,
        },
        .module_root => .{
            .module_name = plan.package.name,
            .public_api_only = true,
        },
        .recursive => .{
            .public_api_only = false,
        },
    };

    const text_options = docent.output.stderrTextOptions(io, textFormat(args.format), .auto, path_display_root);

    for (plan.resolved_targets) |rt| {
        if (rt.status == .linted) {
            for (rt.files) |path| {
                const gptr = try linted_files.getOrPut(path);
                if (gptr.found_existing) continue;

                if (try lintSingleFile(allocator, io, path, rule_set, lint_options, library_entry_roots_owned, &all_diagnostics, &summary, args.fail_fast)) {
                    should_stop = true;
                    break;
                }
            }
        }
        if (should_stop) break;
    }

    if (!should_stop) {
        for (plan.extra_lint_files) |path| {
            const gptr = try linted_files.getOrPut(path);
            if (gptr.found_existing) continue;

            if (try lintSingleFile(allocator, io, path, rule_set, lint_options, library_entry_roots_owned, &all_diagnostics, &summary, args.fail_fast)) {
                should_stop = true;
                break;
            }
        }
    }

    if (args.format == .json) {
        try docent.output.printJsonStdout(io, allocator, all_diagnostics.items);
    } else {
        try docent.output.printDiagnosticsStderr(io, all_diagnostics.items, text_options);
        const had_diagnostics = summary.errors > 0 or summary.warnings > 0;
        try docent.output.printSummaryStderr(io, summary, docent.output.stderrSummaryOptions(io, "docent", .auto), had_diagnostics);
    }

    if (summary.hasErrors()) {
        std.process.exit(1);
    }
}

fn failFastMatches(ff: FailFast, severity: docent.SeverityLevel) bool {
    return switch (ff) {
        .none => false,
        .@"error" => severity.isError(),
        .warn => severity == .warn,
        .any => severity == .warn or severity.isError(),
    };
}

// Format the error type to a prettier message
fn formatError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "file not found",
        docent.manifest.Error.ManifestNotFound => "manifest 'build.zig.zon' not found in current or parent directories",
        docent.manifest.Error.InvalidManifestPath => "invalid manifest path",
        docent.manifest.Error.ManifestPathsNotFound => "'.paths' field not found in manifest",
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

fn lintSingleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rule_set: docent.RuleSet,
    lint_options: docent.LintOptions,
    library_entry_roots: []const []const u8,
    all_diagnostics: *std.ArrayList(docent.Diagnostic),
    summary: *docent.output.Summary,
    fail_fast: FailFast,
) !bool {
    var result = docent.lintFile(allocator, io, path, rule_set, lint_options, library_entry_roots) catch |err| {
        try printStderr(io, "error: failed to lint '{s}': {}\n", .{ path, err });
        return false;
    };
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        summary.observe(d);
        try all_diagnostics.append(allocator, try docent.Diagnostic.cloneAlloc(d, allocator));

        if (failFastMatches(fail_fast, d.severity)) return true;
    }

    return false;
}

fn textFormat(mode: OutputMode) docent.output.TextFormat {
    return switch (mode) {
        .pretty => .pretty,
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
