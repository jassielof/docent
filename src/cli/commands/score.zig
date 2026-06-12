//! `docent score` — Go Report Card-style project quality score.

const std = @import("std");

const carnaval = @import("carnaval");
const docent = @import("docent");
const fangz = @import("fangz");

const check_shared = @import("../check_shared.zig");

pub fn register(root: *fangz.Command) !void {
    const score_cmd = try root.addSubcommand(.{
        .name = "score",
        .brief = "Show a Go Report Card-style quality score",
        .description =
        \\Compute a weighted quality score for the project, similar to Go Report Card.
        \\Checks include `zig fmt`, documentation, style, complexity, LICENSE, and README.
        \\Always exits successfully after printing the report.
        ,
    });

    try check_shared.registerTargetFlags(score_cmd, .{ .persistent = false, .positionals = true });
    score_cmd.setHooks(.{ .run = &run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const args = try ctx.extract(check_shared.TargetArgs);

    const rule_set = docent.config.loadRuleSeveritiesFromCli(allocator, io, args.config_path) catch |err| {
        try printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };

    var plan = check_shared.gatherPlan(allocator, io, args) catch |err| {
        try printStderr(io, "error: failed to build lint plan: {}\n", .{err});
        std.process.exit(1);
    };
    defer plan.deinit(allocator);

    var report = docent.score.gather(allocator, io, .{
        .plan = &plan,
        .rule_set = rule_set,
        .config_path = args.config_path,
        .format_paths = args.positionals,
    }) catch |err| {
        try printStderr(io, "error: failed to compute score: {}\n", .{err});
        std.process.exit(1);
    };
    defer report.deinit(allocator);

    try printReport(io, report);
}

fn printReport(io: std.Io, report: docent.score.Report) !void {
    const profile = carnaval.colorProfileForHandle(std.Io.File.stdout().handle);
    var buf: [16384]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const w = &out.interface;

    try carnaval.Style.init().bolded().renderWithProfile("Grade .......... ", w, profile);
    try carnaval.Style.init().bolded().fg(.{ .ansi16 = .green }).renderWithProfile(report.grade.label(), w, profile);
    try w.print("  {d:.1}%\n", .{report.average});
    try w.print("Files ................ {d}\n", .{report.files});
    try w.print("Issues ................. {d}\n\n", .{report.issues});

    for (report.checks) |check| {
        try w.print("{s}", .{check.name});
        const pad = if (check.name.len < 18) 18 - check.name.len else 0;
        for (0..pad) |_| try w.writeAll(" ");
        try w.print(" {d:.0}%\n", .{check.percentage});
        if (check.error_message) |msg| {
            try carnaval.Style.init().dimmed().renderWithProfile(msg, w, profile);
            try w.writeAll("\n");
        }
    }

    try w.flush();
}

fn printStderr(io: std.Io, comptime fmt: []const u8, fmt_args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    try stderr.interface.print(fmt, fmt_args);
    try stderr.interface.flush();
}
