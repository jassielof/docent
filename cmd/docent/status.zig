//! Reports the effective lint plan: project metadata, lint targets, and rule severities.
const std = @import("std");
const builtin = @import("builtin");

const carnaval = @import("carnaval");
const docent = @import("docent");
const check_shared = docent.check_shared;
const cli_flags = docent.flags;
const fangz = @import("fangz");

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
        .name = "include-deps",
        .brief = "List build targets and module roots discovered in path dependencies",
        .default = false,
    });

    try status_cmd.addFlag(bool, .{
        .name = "build-script",
        .brief = "Include the build script module and everything it depends on to be analyzed",
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
        include_deps: bool = false,
        build_script: bool = false,
    };

    const args = try ctx.extract(Args);

    const rule_set = docent.config.loadRuleSeveritiesFromCli(
        allocator,
        io,
        args.config_path,
    ) catch |err| {
        try printStderr(
            io,
            "error: {s}\n",
            .{docent.config.formatError(err)},
        );
        std.process.exit(1);
    };

    var cfg = docent.config.loadConfigFromCli(
        allocator,
        io,
        args.config_path,
    ) catch |err| {
        try printStderr(
            io,
            "error: {s}\n",
            .{docent.config.formatError(err)},
        );
        std.process.exit(1);
    };
    defer cfg.deinit(allocator);

    var plan = docent.status_plan.gather(allocator, io, .{
        .lib = args.lib,
        .bins = args.bins,
        .bin_names = args.bin,
        .tests = args.tests,
        .test_names = args.@"test",
        .deps = args.deps,
        .build_script = args.build_script,
        .positionals = if (args.positionals.len > 0) args.positionals else cfg.check.include,
        .inherit_manifest_paths = args.positionals.len == 0 and cfg.check.inherit_manifest,
        .exclude_paths = cfg.check.exclude,
        .color_profile = carnaval.colorProfileForHandle(std.Io.File.stdout().handle),
    }) catch |err| {
        try printStderr(
            io,
            "error: failed to build lint plan: {}\n",
            .{err},
        );
        std.process.exit(1);
    };
    defer plan.deinit(allocator);

    const config_path = docent.config.resolveConfigPathForDisplay(
        allocator,
        io,
        args.config_path,
    ) catch |err| {
        try printStderr(
            io,
            "error: {s}\n",
            .{docent.config.formatError(err)},
        );
        std.process.exit(1);
    };
    if (config_path) |path| {
        defer allocator.free(path);
        try printStatusReport(
            allocator,
            io,
            plan,
            rule_set,
            path,
            args.include_deps,
        );
    } else {
        try printStatusReport(
            allocator,
            io,
            plan,
            rule_set,
            null,
            args.include_deps,
        );
    }
}

pub fn printStatusReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    plan: docent.status_plan.Plan,
    rule_set: docent.RuleSeverities,
    config_path: ?[]const u8,
    include_deps: bool,
) !void {
    const profile = carnaval.colorProfileForHandle(std.Io.File.stdout().handle);
    var buf: [32768]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const w = &out.interface;

    try carnaval.Style.init().bolded().renderWithProfile(
        "Docent status\n\n",
        w,
        profile,
    );

    try sectionHeading(
        w,
        profile,
        "Project",
    );
    if (plan.package.name) |name| try w.print("  name:      {s}\n", .{name});
    if (plan.package.version) |version| try w.print("  version:   {s}\n", .{version});
    if (plan.package.manifest_path) |mp| {
        try w.print("  manifest:  {s}\n", .{mp});
    } else {
        try w.print("  manifest:  (none found)\n", .{});
    }
    if (config_path) |cp| {
        try w.print("  config:    ", .{});
        try writeNativePath(w, cp);
        try w.print("\n", .{});
    } else {
        try w.print("  config:    (none found; using rule defaults)\n", .{});
    }
    try w.print("  root:      {s}\n\n", .{plan.package.project_root});

    try sectionHeading(
        w,
        profile,
        "Target Selection Report",
    );
    if (plan.path_mode != .project) {
        const mode_label: []const u8 = switch (plan.path_mode) {
            .module_root => "module root",
            .recursive => "recursive",
            .project => unreachable,
        };
        try w.print("  Path mode: {s} (build.zig target discovery skipped).\n", .{mode_label});
        try w.print("  Selected paths:\n", .{});
        for (plan.selected_paths) |path| {
            const display = try docent.scan.target.pathRelativeTo(
                allocator,
                plan.package.project_root,
                path,
            );
            defer allocator.free(display);
            try w.print("    - {s}\n", .{display});
        }
        if (plan.manifest_paths.len > 0) {
            try w.print("  Also inherited from manifest:\n", .{});
            try printManifestPaths(allocator, w, plan);
        }
        try w.print("\n", .{});
    } else {
        if (plan.resolved_targets.len == 0) {
            if (plan.manifest_paths.len > 0) {
                try w.print("  Inherited from manifest:\n", .{});
                try printManifestPaths(allocator, w, plan);
            } else {
                try w.print("  No paths selected.\n", .{});
            }
            try w.print("\n", .{});
        } else {
            for (plan.resolved_targets) |rt| {
                try printResolvedTarget(
                    w,
                    profile,
                    rt,
                );
            }
            if (plan.extra_lint_files.len > 0) {
                try w.print("  Extra/Build files:\n", .{});
                for (plan.extra_lint_files) |f| {
                    const display = try docent.scan.target.pathRelativeTo(
                        allocator,
                        plan.package.project_root,
                        f,
                    );
                    defer allocator.free(display);
                    try w.print("    - {s}\n", .{display});
                }
                try w.print("\n", .{});
            }
        }
    }

    try sectionHeading(
        w,
        profile,
        "Excluded dependencies",
    );
    if (plan.targeting.exclude_roots.len == 0) {
        try w.print("  (none; use --deps to include path dependencies)\n\n", .{});
    } else {
        for (plan.targeting.exclude_roots) |dep| {
            const rel = try docent.scan.target.pathRelativeTo(
                allocator,
                plan.package.project_root,
                dep,
            );
            defer allocator.free(rel);
            try w.print("  - {s}\n", .{rel});
        }
        try w.print("  Skipped unless --deps is set.\n\n", .{});
    }

    if (include_deps) {
        try printDependencyTargets(
            allocator,
            io,
            w,
            profile,
            plan,
        );
    }

    try sectionHeading(
        w,
        profile,
        "Effective rules",
    );
    try check_shared.printCategorizedEffectiveRules(
        allocator,
        w,
        profile,
        rule_set,
    );
    try w.print("\n", .{});

    try carnaval.Style.init().dimmed().renderWithProfile(
        "Run `docent` to lint and enforce severities.\n",
        w,
        profile,
    );
    try w.flush();
}

/// Writes a path using the host platform's conventional separator.
fn writeNativePath(w: *std.Io.Writer, path: []const u8) !void {
    if (builtin.os.tag != .windows) {
        try w.print("{s}", .{path});
        return;
    }

    for (path) |char| {
        try w.writeByte(if (char == '/') '\\' else char);
    }
}

fn printManifestPaths(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    plan: docent.status_plan.Plan,
) !void {
    for (plan.manifest_paths) |path| {
        const display = try docent.scan.target.pathRelativeTo(
            allocator,
            plan.package.project_root,
            path,
        );
        defer allocator.free(display);
        try w.print("    - {s}", .{display});
        if (containsExcludedDependency(path, plan.targeting.exclude_roots)) {
            try w.writeAll(" (declared path dependencies excluded)");
        }
        try w.writeAll("\n");
    }
}

fn containsExcludedDependency(path: []const u8, excluded_roots: []const []const u8) bool {
    for (excluded_roots) |root| {
        if (!std.mem.startsWith(u8, root, path)) continue;
        if (root.len == path.len or root[path.len] == '/' or root[path.len] == '\\') return true;
    }
    return false;
}

fn printResolvedTarget(
    w: *std.Io.Writer,
    profile: carnaval.ColorProfile,
    rt: docent.status_plan.ResolvedTarget,
) !void {
    try w.writeAll("  Target: ");
    try carnaval.Style.init().italicized().renderWithProfile(
        rt.name,
        w,
        profile,
    );
    try w.writeAll(" (");

    const kind_style = targetKindStyle(rt.kind);
    const kind_name = targetKindLabel(rt.kind);

    try kind_style.renderWithProfile(
        kind_name,
        w,
        profile,
    );
    try w.writeAll(")\n");

    try w.writeAll("    - ");
    try carnaval.Style.init().bolded().renderWithProfile(
        "Module root",
        w,
        profile,
    );
    try w.print(": {s}\n", .{rt.root_source_file});

    try w.writeAll("    - ");
    try carnaval.Style.init().bolded().renderWithProfile(
        "Status",
        w,
        profile,
    );
    try w.writeAll(": ");
    if (rt.status == .linted) {
        try carnaval.Style.init().fg(.{ .ansi16 = .green }).renderWithProfile(
            "LINTED",
            w,
            profile,
        );
    } else {
        try carnaval.Style.init().dimmed().renderWithProfile(
            "SKIPPED",
            w,
            profile,
        );
    }
    try w.writeAll("\n");

    try w.writeAll("    - ");
    try carnaval.Style.init().bolded().renderWithProfile(
        "Reason",
        w,
        profile,
    );
    try w.print(": {s}\n", .{rt.reason});
    if (rt.status == .linted) {
        try w.writeAll("    - ");
        try carnaval.Style.init().bolded().renderWithProfile(
            "Reachable files",
            w,
            profile,
        );
        try w.print(": {d}\n", .{rt.files.len});
    }
    try w.print("\n", .{});
}

fn targetKindStyle(kind: docent.build_scan.TargetKind) carnaval.Style {
    return switch (kind) {
        .lib => carnaval.Style.init().fg(.{ .ansi16 = .cyan }),
        .bin => carnaval.Style.init().fg(.{ .ansi16 = .yellow }),
        .test_target => carnaval.Style.init().fg(.{ .ansi16 = .magenta }),
    };
}

fn targetKindLabel(kind: docent.build_scan.TargetKind) []const u8 {
    return switch (kind) {
        .lib => "Library",
        .bin => "Executable",
        .test_target => "Test",
    };
}

fn printDependencyTargets(
    allocator: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    profile: carnaval.ColorProfile,
    plan: docent.status_plan.Plan,
) !void {
    if (plan.targeting.exclude_roots.len == 0) return;

    try sectionHeading(
        w,
        profile,
        "Dependency targets",
    );

    for (plan.targeting.exclude_roots) |dep_root| {
        const rel = try docent.scan.target.pathRelativeTo(
            allocator,
            plan.package.project_root,
            dep_root,
        );
        defer allocator.free(rel);

        try w.writeAll("  ");
        try carnaval.Style.init().italicized().renderWithProfile(
            rel,
            w,
            profile,
        );
        try w.print("\n", .{});

        var scanned = try docent.build_scan.scanProjectBuildScript(
            allocator,
            io,
            dep_root,
        );
        defer if (scanned) |*scan| scan.deinit(allocator);

        if (scanned) |scan| {
            if (scan.targets.len > 0) {
                for (scan.targets) |target| {
                    try w.writeAll("    - ");
                    try carnaval.Style.init().italicized().renderWithProfile(
                        target.name,
                        w,
                        profile,
                    );
                    try w.writeAll(" (");
                    try targetKindStyle(target.kind).renderWithProfile(
                        targetKindLabel(target.kind),
                        w,
                        profile,
                    );
                    try w.print("): {s}\n", .{target.root_source_file});
                }
                try w.print("\n", .{});
                continue;
            }
        }

        var entrypoints: std.ArrayList([]const u8) = .empty;
        defer docent.scan.target.deinitOwnedPaths(allocator, &entrypoints);
        try docent.scan.target.collectDirectoryEntrypoints(
            allocator,
            io,
            dep_root,
            plan.targeting,
            &entrypoints,
        );

        if (entrypoints.items.len == 0) {
            try w.print("    (no module roots found)\n\n", .{});
            continue;
        }

        for (entrypoints.items) |entry| {
            const entry_rel = try docent.scan.target.pathRelativeTo(
                allocator,
                dep_root,
                entry,
            );
            defer allocator.free(entry_rel);
            try w.print("    - module root: {s}\n", .{entry_rel});
        }
        try w.print("\n", .{});
    }
}

fn sectionHeading(
    w: *std.Io.Writer,
    profile: carnaval.ColorProfile,
    title: []const u8,
) !void {
    try carnaval.Style.init().bolded().renderWithProfile(
        title,
        w,
        profile,
    );
    try w.print("\n", .{});
}

fn printStderr(
    io: std.Io,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    try stderr.interface.print(fmt, args);
    try stderr.interface.flush();
}
