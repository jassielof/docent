//! Reports the effective lint plan: project metadata, lint targets, and rule severities.
const std = @import("std");

const carnaval = @import("carnaval");
const docent = @import("docent");
const fangz = @import("fangz");

const cli_flags = @import("../flags.zig");

pub fn register(root: *fangz.Command) !void {
    const status_cmd = try root.addSubcommand(.{
        .name = "status",
        .brief = "Show project lint plan and effective rules",
        .description = "Print project metadata, lint scan roots, excluded dependencies, resolved targets, and effective rule severities. Always exits 0 after a successful report (use `docent` to lint and enforce severities).",
    });

    try status_cmd.addPositional(.{
        .name = "paths",
        .brief = "Files or directories to summarize. If omitted, uses package paths from build.zig.zon when available.",
        .variadic = true,
    });

    try cli_flags.registerConfigPath(status_cmd);

    try status_cmd.addFlag(bool, .{
        .name = "lib",
        .brief = "Lint library targets only (default)",
        .default = false,
    });

    try status_cmd.addFlag(bool, .{
        .name = "bins",
        .brief = "Lint all binary targets",
        .default = false,
    });

    try status_cmd.addFlag([]const []const u8, .{
        .name = "bin",
        .brief = "Lint specific binary by name (repeatable)",
    });

    try status_cmd.addFlag(bool, .{
        .name = "tests",
        .brief = "Lint all test targets",
        .default = false,
    });

    try status_cmd.addFlag([]const []const u8, .{
        .name = "test",
        .brief = "Lint specific test by name (repeatable)",
    });

    try status_cmd.addFlag(bool, .{
        .name = "deps",
        .brief = "Also lint files under path dependencies from build.zig.zon",
        .default = false,
    });

    try status_cmd.addFlag(bool, .{
        .name = "build-script",
        .brief = "Include build.zig and build/*.zig files in lint targets",
        .default = false,
    });

    status_cmd.setHooks(.{ .run = &run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const Args = struct {
        positionals: []const []const u8 = &.{},
        config_path: ?[]const u8 = null,
        lib: bool = false,
        bins: bool = false,
        bin: []const []const u8 = &.{},
        tests: bool = false,
        @"test": []const []const u8 = &.{},
        deps: bool = false,
        build_script: bool = false,
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
        .color_profile = carnaval.colorProfileForHandle(std.Io.File.stdout().handle),
    }) catch |err| {
        try printStderr(io, "error: failed to build lint plan: {}\n", .{err});
        std.process.exit(1);
    };
    defer plan.deinit(allocator);

    const config_path = docent.config.resolveConfigPathForDisplay(allocator, io, args.config_path) catch |err| {
        try printStderr(io, "error: {s}\n", .{docent.config.formatError(err)});
        std.process.exit(1);
    };
    if (config_path) |path| {
        defer allocator.free(path);
        try printStatusReport(io, plan, rule_set, path);
    } else {
        try printStatusReport(io, plan, rule_set, null);
    }
}

pub fn printStatusReport(
    io: std.Io,
    plan: docent.status_plan.Plan,
    rule_set: docent.RuleSet,
    config_path: ?[]const u8,
) !void {
    const profile = carnaval.colorProfileForHandle(std.Io.File.stdout().handle);
    var buf: [32768]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const w = &out.interface;

    try carnaval.Style.init().bolded().renderWithProfile("Docent status\n\n", w, profile);

    try sectionHeading(w, profile, "Project");
    if (plan.package.name) |name| try w.print("  name:      {s}\n", .{name});
    if (plan.package.version) |version| try w.print("  version:   {s}\n", .{version});
    if (plan.package.manifest_path) |mp| {
        try w.print("  manifest:  {s}\n", .{mp});
    } else {
        try w.print("  manifest:  (none found)\n", .{});
    }
    if (config_path) |cp| {
        try w.print("  config:    {s}\n", .{cp});
    } else {
        try w.print("  config:    (none found; using rule defaults)\n", .{});
    }
    try w.print("  root:      {s}\n\n", .{plan.package.project_root});

    try sectionHeading(w, profile, "Target Selection Report");
    if (plan.explicit_paths) {
        try w.print("  Bypassed build.zig analysis due to explicit path override.\n", .{});
        try w.print("  Target files:\n", .{});
        for (plan.extra_lint_files) |path| {
            try w.print("    - {s}\n", .{path});
        }
        try w.print("\n", .{});
    } else {
        if (plan.resolved_targets.len == 0) {
            try w.print("  No targets resolved from build.zig.\n", .{});
            if (plan.extra_lint_files.len > 0) {
                try w.print("  Fallback files (from build.zig.zon or project root):\n", .{});
                for (plan.extra_lint_files) |path| {
                    try w.print("    - {s}\n", .{path});
                }
            } else {
                try w.print("  No source files found for linting.\n", .{});
            }
            try w.print("\n", .{});
        } else {
            for (plan.resolved_targets) |rt| {
                try w.writeAll("  Target: ");
                try carnaval.Style.init().italicized().renderWithProfile(
                    rt.name,
                    w,
                    profile,
                );

                try w.writeAll(" (");

                const kind_style = switch (rt.kind) {
                    .lib => carnaval.Style.init().fg(.{ .ansi16 = .cyan }),
                    .bin => carnaval.Style.init().fg(.{ .ansi16 = .green }),
                    .test_target => carnaval.Style.init().fg(.{ .ansi16 = .magenta }),
                };

                const kind_name = switch (rt.kind) {
                    .lib => "Library",
                    .bin => "Executable",
                    .test_target => "Test",
                };

                try kind_style.renderWithProfile(kind_name, w, profile);
                try w.writeAll(")\n");

                try w.writeAll("    - ");
                try carnaval.Style.init().bolded().renderWithProfile("Module root", w, profile);
                try w.print(": {s}\n", .{rt.root_source_file});

                try w.writeAll("    - ");
                try carnaval.Style.init().bolded().renderWithProfile("Status", w, profile);
                try w.writeAll(": ");
                if (rt.status == .linted) {
                    try carnaval.Style.init().fg(.{ .ansi16 = .green }).renderWithProfile("LINTED", w, profile);
                } else {
                    try carnaval.Style.init().dimmed().renderWithProfile("SKIPPED", w, profile);
                }
                try w.writeAll("\n");

                try w.writeAll("    - ");
                try carnaval.Style.init().bolded().renderWithProfile("Reason", w, profile);
                try w.print(": {s}\n", .{rt.reason});
                if (rt.status == .linted) {
                    try w.writeAll("    - ");
                    try carnaval.Style.init().bolded().renderWithProfile("Reachable files", w, profile);
                    try w.print(": {d}\n", .{rt.files.len});
                }
                try w.print("\n", .{});
            }
            if (plan.extra_lint_files.len > 0) {
                try w.print("  Extra/Build files:\n", .{});
                for (plan.extra_lint_files) |f| {
                    try w.print("    - {s}\n", .{f});
                }
                try w.print("\n", .{});
            }
        }
    }

    try sectionHeading(w, profile, "Excluded dependencies");
    if (plan.targeting.exclude_roots.len == 0) {
        try w.print("  (none; use --deps to include path dependencies)\n\n", .{});
    } else {
        for (plan.targeting.exclude_roots) |dep| {
            try w.print("  - {s}\n", .{dep});
        }
        try w.print("  Skipped unless --deps is set.\n\n", .{});
    }

    try sectionHeading(w, profile, "Effective rules");
    inline for (@typeInfo(docent.RuleSet).@"struct".fields) |f| {
        const level = @field(rule_set, f.name);
        try w.print("  {s}", .{f.name});
        var pad: usize = 0;
        while (pad < 32 -| f.name.len) : (pad += 1) try w.print(" ", .{});
        try w.print("{s}\n", .{@tagName(level)});
    }
    try w.print("\n", .{});

    try carnaval.Style.init().dimmed().renderWithProfile(
        "Run `docent` to lint and enforce severities.\n",
        w,
        profile,
    );
    try w.flush();
}

fn sectionHeading(w: *std.Io.Writer, profile: carnaval.ColorProfile, title: []const u8) !void {
    try carnaval.Style.init().bolded().renderWithProfile(title, w, profile);
    try w.print("\n", .{});
}

fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    try stderr.interface.print(fmt, args);
    try stderr.interface.flush();
}
