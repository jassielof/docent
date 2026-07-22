const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");
const fmt = @import("fmt");

pub fn register(root: *fangz.Command) !void {
    const fmt_cmd = try root.addSubcommand(.{
        .name = "fmt",
        .brief = "Format Zig source code",
        .description = "Filesystem-based formatter: recursively walks directories and formats every `.zig` / `.zon` file, including orphans not reachable from a module root. Path filters may be set in `.config/docent.toml` under `[fmt].include` / `[fmt].exclude` (Deno-style); CLI paths override `include`, and CLI `--exclude` merges with config `exclude`.",
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
        .brief = "Exclude file or directory from formatting (merged with [fmt].exclude)",
        .multi = true,
        .value_hint = "PATH",
    });

    try fmt_cmd.addFlag(bool, .{
        .name = "zon",
        .brief = "Treat all input files as ZON, regardless of file extension",
    });

    try fmt_cmd.addPositional(.{
        .name = "paths",
        .brief = "Files or directories to format. If omitted, uses [fmt].include from config when set.",
        .variadic = true,
    });

    fmt_cmd.hooks.run = &runFmt;
}

fn runFmt(ctx: *fangz.ParseContext) anyerror!void {
    const gpa = ctx.allocator;
    const io = ctx.io;

    const stdin_flag = ctx.boolFlag("stdin") orelse false;
    const check_flag = ctx.boolFlag("check") orelse false;
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

    if (stdin_flag and input_paths.len != 0) {
        std.process.fatal("cannot use --stdin with positional arguments", .{});
    }

    const paths: []const []const u8 = if (stdin_flag)
        &.{}
    else if (input_paths.len > 0)
        input_paths
    else if (config.include.len > 0)
        config.include
    else
        std.process.fatal("expected at least one file or directory argument (or set [fmt].include in .config/docent.toml)", .{});

    var excluded: std.ArrayList([]const u8) = .empty;
    defer excluded.deinit(gpa);
    try excluded.appendSlice(gpa, config.exclude);
    try excluded.appendSlice(gpa, cli_excluded);

    const opts: fmt.Options = .{
        .check = check_flag,
        .check_format = check_format,
        .ast_check = ast_check_flag,
        .zon = zon_flag,
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
