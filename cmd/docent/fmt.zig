const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");
const fmt = @import("fmt");

pub fn register(root: *fangz.Command) !void {
    const fmt_cmd = try root.addSubcommand(.{
        .name = "fmt",
        .brief = "Format Zig source code",
        .description = "Filesystem-based formatter: recursively walks paths and formats every Zig or ZON file. CLI paths override `[fmt].include`; when neither is set, package paths from the nearest build.zig.zon are used. Non-Zig manifest files and local path dependencies are ignored. CLI `--exclude` merges with config `exclude`.",
    });

    try fmt_cmd.addFlag(bool, .{
        .name = "stdin",
        .brief = "Format source from stdin and write the result to stdout",
    });

    try fmt_cmd.addFlag(bool, .{
        .name = "check",
        .brief = "List non-conforming files and exit with an error if the list is non-empty",
    });

    try fmt_cmd.addFlag(bool, .{
        .name = "fail-fast",
        .brief = "Stop after the first non-conforming file",
    });

    try fmt_cmd.addFlag(bool, .{
        .name = "ast-check",
        .brief = "Validate formatted source with Zig's AST checker",
    });

    try fmt_cmd.addFlag(fmt.CheckFormat, .{
        .name = "format",
        .short = 'f',
        .brief = "Output format for --check mode",
        .default = .pretty,
        .value_hint = "FORMAT",
    });

    try fmt_cmd.addFlag([]const []const u8, .{
        .name = "exclude",
        .brief = "Exclude paths from formatting (merged with `[fmt].exclude`)",
        .multi = true,
        .value_hint = "PATH",
    });

    try fmt_cmd.addFlag(bool, .{
        .name = "zon",
        .brief = "Treat all input paths as ZON, regardless of file extension.",
    });

    try fmt_cmd.addPositional(.{
        .name = "paths",
        .brief = "Paths to format. Defaults to `[fmt].include`, then package paths from build.zig.zon.",
        .variadic = true,
    });

    fmt_cmd.hooks.run = &runFmt;
}

fn runFmt(ctx: *fangz.ParseContext) anyerror!void {
    const gpa = ctx.allocator;
    const io = ctx.io;

    const stdin_flag = ctx.boolFlag("stdin") orelse false;
    const check_flag = ctx.boolFlag("check") orelse false;
    const fail_fast_flag = ctx.boolFlag("fail-fast") orelse false;
    const check_format = ctx.enumFlag(fmt.CheckFormat, "format") orelse .pretty;
    const ast_check_flag = ctx.boolFlag("ast-check") orelse false;
    const zon_flag = ctx.boolFlag("zon") orelse false;
    const cli_excluded = ctx.stringListFlag("exclude") orelse &.{};
    const input_paths = ctx.positionals.items;

    var config: fmt.Config = docent.config.loadFmtOptionsFromCli(
        gpa,
        io,
        null,
    ) catch .{};
    defer config.deinit(gpa);

    var manifest_paths: std.ArrayList([]const u8) = .empty;
    defer docent.manifest.deinitOwnedPaths(gpa, &manifest_paths);
    var manifest_dependency_roots: std.ArrayList([]const u8) = .empty;
    defer docent.manifest.deinitOwnedPaths(gpa, &manifest_dependency_roots);
    var using_manifest_defaults = false;

    if (stdin_flag and input_paths.len != 0) {
        std.process.fatal("cannot use --stdin with positional arguments", .{});
    }

    const paths: []const []const u8 = paths: {
        if (stdin_flag) break :paths &.{};
        if (input_paths.len > 0) break :paths input_paths;
        if (config.include.len > 0) break :paths config.include;

        const manifest_path = docent.manifest.findNearestManifestPath(gpa, io) catch
            std.process.fatal(
                "expected at least one file or directory argument, `[fmt].include`, or a build.zig.zon",
                .{},
            );
        defer gpa.free(manifest_path);

        var package_paths = docent.manifest.loadPackagePaths(
            gpa,
            io,
            manifest_path,
        ) catch |err| switch (err) {
            error.ManifestPathsNotFound => fallback: {
                var fallback_paths: std.ArrayList([]const u8) = .empty;
                const project_root = std.fs.path.dirname(manifest_path) orelse ".";
                try fallback_paths.append(gpa, try gpa.dupe(u8, project_root));
                break :fallback fallback_paths;
            },
            else => return err,
        };
        defer docent.manifest.deinitOwnedPaths(gpa, &package_paths);

        for (package_paths.items) |path| {
            const stat = std.Io.Dir.cwd().statFile(
                io,
                path,
                .{},
            ) catch |err| switch (err) {
                // Preserve useful errors for missing source paths while ignoring
                // missing non-source package metadata entries.
                error.FileNotFound => {
                    if (isFormatSourcePath(path)) {
                        try manifest_paths.append(gpa, try gpa.dupe(u8, path));
                    }
                    continue;
                },
                else => return err,
            };
            if (stat.kind == .directory or isFormatSourcePath(path)) {
                try manifest_paths.append(gpa, try gpa.dupe(u8, path));
            }
        }

        manifest_dependency_roots = docent.manifest.loadDependencyPathRoots(
            gpa,
            io,
            manifest_path,
        ) catch .empty;
        using_manifest_defaults = true;
        break :paths manifest_paths.items;
    };

    var excluded: std.ArrayList([]const u8) = .empty;
    defer excluded.deinit(gpa);
    try excluded.appendSlice(gpa, config.exclude);
    try excluded.appendSlice(gpa, cli_excluded);
    if (using_manifest_defaults) {
        try excluded.appendSlice(gpa, manifest_dependency_roots.items);
    }

    const opts: fmt.Options = .{
        .check = check_flag,
        .check_format = check_format,
        .ast_check = ast_check_flag,
        .zon = zon_flag,
        .fail_fast = fail_fast_flag,
    };

    if (stdin_flag) {
        return fmt.Formatter.formatStdin(
            gpa,
            io,
            opts,
            config,
        );
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);

    var formatter = fmt.Formatter.init(
        gpa,
        io,
        &stdout_writer,
        opts,
        config,
    );
    defer formatter.deinit();

    try formatter.formatPaths(paths, excluded.items);
}

fn isFormatSourcePath(path: []const u8) bool {
    return std.mem.endsWith(
        u8,
        path,
        ".zig",
    ) or
        std.mem.endsWith(
            u8,
            path,
            ".zon",
        );
}

test "manifest defaults recognize only Zig and ZON files" {
    try std.testing.expect(isFormatSourcePath("build.zig"));
    try std.testing.expect(isFormatSourcePath("build.zig.zon"));
    try std.testing.expect(!isFormatSourcePath("README.md"));
    try std.testing.expect(!isFormatSourcePath("LICENSE.txt"));
}
