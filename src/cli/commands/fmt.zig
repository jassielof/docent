const std = @import("std");

const fangz = @import("fangz");
const docent = @import("docent");
const Fmt = docent.Fmt;

// TODO: Output diagnostics should have a similar style to Docent check diagnostics.

pub fn register(root: *fangz.Command) !void {
    const fmt_cmd = try root.addSubcommand(.{
        .name = "fmt",
        .brief = "Format Zig source code",
    });

    // TODO: Standard input might be removed, if there's no real usage outside of testing.
    try fmt_cmd.addFlag(bool, .{
        .name = "stdin",
        .brief = "Format code from stdin; output to stdout",
    });

    try fmt_cmd.addFlag(bool, .{
        .name = "check",
        .brief = "List non-conforming files and exit with an error if the list is non-empty",
    });

    // TODO: Similar to the stdin TODO, if there's no real usage outside of testing, this might be removed. In both cases, if there's testing usage, then keep it just for testing.
    try fmt_cmd.addFlag(bool, .{
        .name = "ast-check",
        .brief = "Run zig ast-check on every file",
    });

    try fmt_cmd.addFlag([]const []const u8, .{
        .name = "exclude",
        .brief = "Exclude file or directory from formatting",
        .multi = true,
        .value_hint = "PATH",
    });

    try fmt_cmd.addFlag(bool, .{
        .name = "zon",
        .brief = "Treat all input files as ZON, regardless of file extension",
    });

    // TODO: Color will always be enabled, there's no reason to not want color, if someone wants to disable it, their terminal will do so.
    try fmt_cmd.addFlag(std.zig.Color, .{
        .name = "color",
        .brief = "Enable or disable colored error messages",
        .default = .auto,
        .value_hint = "WHEN",
    });

    // TODO: Rename to paths instead of files, as paths can be files or directories.
    try fmt_cmd.addPositional(.{
        .name = "files",
        .brief = "Files or directories to format",
        .variadic = true,
    });

    // fmt_cmd.setHooks(.{ .run = &runFmt });

    fmt_cmd.hooks.run = &runFmt;
}

fn runFmt(ctx: *fangz.ParseContext) anyerror!void {
    const gpa = ctx.allocator;
    const io = ctx.io;

    const stdin_flag = ctx.boolFlag("stdin") orelse false;
    const check_flag = ctx.boolFlag("check") orelse false;
    const ast_check_flag = ctx.boolFlag("ast-check") orelse false;
    const zon_flag = ctx.boolFlag("zon") orelse false;
    const color = ctx.enumFlag(std.zig.Color, "color") orelse .auto;
    const excluded_files = ctx.stringListFlag("exclude") orelse &.{};
    const input_files = ctx.positionals.items;

    const opts: Fmt.Options = .{
        .check = check_flag,
        .ast_check = ast_check_flag,
        .zon = zon_flag,
        .color = color,
    };

    const config = Fmt.loadConfig(gpa, io);

    if (stdin_flag) {
        if (input_files.len != 0) {
            std.process.fatal("cannot use --stdin with positional arguments", .{});
        }
        return Fmt.formatStdin(gpa, io, opts, config);
    }

    if (input_files.len == 0) {
        std.process.fatal("expected at least one file or directory argument", .{});
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);

    var formatter = Fmt.init(gpa, io, &stdout_writer, opts, config);
    defer formatter.deinit();

    try formatter.formatPaths(input_files, excluded_files);
}
