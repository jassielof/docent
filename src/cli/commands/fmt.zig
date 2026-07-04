const std = @import("std");

const fangz = @import("fangz");
const docent = @import("docent");
const Fmt = docent.Fmt;

pub fn register(root: *fangz.Command) !void {
    const fmt_cmd = try root.addSubcommand(.{
        .name = "fmt",
        .brief = "Format Zig source code",
    });

    try fmt_cmd.addFlag(bool, .{
        .name = "check",
        .brief = "List non-conforming files and exit with an error if the list is non-empty",
    });

    try fmt_cmd.addFlag(Fmt.CheckFormat, .{
        .name = "format",
        .short = 'f',
        .brief = "Output format for --check mode",
        .default = .pretty,
        .value_hint = "FORMAT",
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

    try fmt_cmd.addPositional(.{
        .name = "paths",
        .brief = "Files or directories to format",
        .variadic = true,
    });

    fmt_cmd.hooks.run = &runFmt;
}

fn runFmt(ctx: *fangz.ParseContext) anyerror!void {
    const gpa = ctx.allocator;
    const io = ctx.io;

    const check_flag = ctx.boolFlag("check") orelse false;
    const check_format = ctx.enumFlag(Fmt.CheckFormat, "format") orelse .pretty;
    const zon_flag = ctx.boolFlag("zon") orelse false;
    const excluded_files = ctx.stringListFlag("exclude") orelse &.{};
    const input_paths = ctx.positionals.items;

    if (input_paths.len == 0) {
        std.process.fatal("expected at least one file or directory argument", .{});
    }

    const opts: Fmt.Options = .{
        .check = check_flag,
        .check_format = check_format,
        .zon = zon_flag,
    };

    const config = Fmt.loadConfig(gpa, io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);

    var formatter = Fmt.init(gpa, io, &stdout_writer, opts, config);
    defer formatter.deinit();

    try formatter.formatPaths(input_paths, excluded_files);
}
