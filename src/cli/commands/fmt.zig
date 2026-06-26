const std = @import("std");

const fangz = @import("fangz");
const docent = @import("docent");
const fmt = docent.fmt;

// TODO: Add an option to enforce braces on single line statements.
// TODO: Add an option to enforce blank newlins after braces or return statements.
// TODO: Add an option to modify the indentation width. I won't add the ability to modify the indentation character, as spaces are generally what's suggested, and I don't like tabs, I'll be open to contributions if someone wants to add that feature.
// TODO: Add an option to sort imports. Only top-level ones.
// TODO: Add an option to auto-wrap.
// TODO: Add an option to enforce a maximum line length.

pub fn register(root: *fangz.Command) !void {
    const fmt_cmd = try root.addSubcommand(.{
        .name = "fmt",
        .brief = "Format Zig source code",
    });

    try fmt_cmd.addFlag(bool, .{
        .name = "stdin",
        .brief = "Format code from stdin; output to stdout",
    });

    try fmt_cmd.addFlag(bool, .{
        .name = "check",
        .brief = "List non-conforming files and exit with an error if the list is non-empty",
    });

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

    try fmt_cmd.addFlag(std.zig.Color, .{
        .name = "color",
        .brief = "Enable or disable colored error messages",
        .default = .auto,
        .value_hint = "WHEN",
    });

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

    const opts: fmt.Options = .{
        .check = check_flag,
        .ast_check = ast_check_flag,
        .zon = zon_flag,
        .color = color,
    };

    const config = fmt.loadConfig(gpa, io);

    if (stdin_flag) {
        if (input_files.len != 0) {
            std.process.fatal("cannot use --stdin with positional arguments", .{});
        }
        return fmt.formatStdin(gpa, io, opts, config);
    }

    if (input_files.len == 0) {
        std.process.fatal("expected at least one file or directory argument", .{});
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);

    var fmt_check = fmt.Fmt.init(gpa, io, &stdout_writer, opts, config);
    defer fmt_check.deinit();

    try fmt.formatPaths(&fmt_check, input_files, excluded_files);
}
