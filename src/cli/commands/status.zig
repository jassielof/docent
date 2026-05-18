const std = @import("std");

const carnaval = @import("carnaval");
const docent = @import("docent");
const fangz = @import("fangz");

const rule_config = @import("../rule_config.zig");
const rules_command = @import("rules.zig");

const sample_target_limit = 5;

pub fn register(root: *fangz.Command, key_value_help: *const fangz.Command.KeyValueHelp) !void {
    const status_cmd = try root.addSubcommand(.{
        .name = "status",
        .brief = "Show project lint plan and diagnostic summary",
        .description =
        \\Print a quick overview of the project, lint scan roots, excluded dependencies,
        \\effective rule severities, and diagnostic counts. Always exits 0 after a
        \\successful report (use `docent` to enforce severities).
        ,
    });

    try status_cmd.addPositional(.{
        .name = "paths",
        .brief = "Files or directories to summarize. If omitted, uses package paths from build.zig.zon when available.",
        .variadic = true,
    });

    try status_cmd.addFlag(fangz.KeyValueList, .{
        .name = "rule",
        .short = 'r',
        .brief = "Override one rule severity for the summary scan",
        .description = "Repeat to override multiple rules. Run `docent rules` for defaults.",
        .key_metavar = "RULE",
        .value_metavar = "LEVEL",
        .allowed_keys = docent.RuleSet.fieldNames(),
        .allowed_values = &.{ "allow", "warn", "deny", "forbid" },
        .key_value_help = key_value_help,
        .examples = rules_command.flag_examples,
        .allowed_values_style = .bullet_list,
    });

    try status_cmd.addFlag(?rule_config.AllPreset, .{
        .name = "all",
        .brief = "Apply one severity to all rules for the summary scan",
        .value_hint = "LEVEL",
    });

    try status_cmd.addFlag(bool, .{
        .name = "include-build-scripts",
        .brief = "Include build.zig and build/*.zig files in lint targets",
        .default = false,
    });

    try status_cmd.addFlag(bool, .{
        .name = "lint-dependencies",
        .brief = "Also lint files under path dependencies from build.zig.zon",
        .default = false,
    });

    try status_cmd.addFlag(bool, .{
        .name = "no-scan",
        .brief = "Skip running the linter; only show the scan plan",
        .default = false,
    });

    status_cmd.setHooks(.{ .run = &run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const Args = struct {
        positionals: []const []const u8 = &.{},
        rule: fangz.KeyValueList = &.{},
        all: ?rule_config.AllPreset = null,
        include_build_scripts: bool = false,
        lint_dependencies: bool = false,
        no_scan: bool = false,
    };

    const args = try ctx.extract(Args);

    var rule_set: docent.RuleSet = .{};
    if (args.all) |preset| rule_set = rule_config.allPresetToRuleSet(preset);

    for (args.rule) |override| {
        rule_config.applyRuleOverride(&rule_set, override) catch |err| {
            try printStderr(io, "error: invalid --rule value '{s}={s}': {s}\n", .{
                override.key,
                override.value,
                rule_config.formatRuleConfigError(err),
            });
            std.process.exit(1);
        };
    }

    var plan = docent.status_plan.gather(allocator, io, .{
        .include_build_scripts = args.include_build_scripts,
        .lint_dependencies = args.lint_dependencies,
        .positionals = args.positionals,
    }) catch |err| {
        try printStderr(io, "error: failed to build lint plan: {}\n", .{err});
        std.process.exit(1);
    };
    defer plan.deinit(allocator);

    var build_scan_result: ?docent.build_scan.Result = null;
    if (docent.build_scan.scanProjectBuildScript(allocator, io, plan.package.project_root)) |scan| {
        build_scan_result = scan;
    } else |_| {}
    defer if (build_scan_result) |*r| r.deinit(allocator);

    try printStatusReport(allocator, io, plan, build_scan_result, rule_set, args.no_scan);
}

pub fn printStatusReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    plan: docent.status_plan.Plan,
    build_scan_result: ?docent.build_scan.Result,
    rule_set: docent.RuleSet,
    no_scan: bool,
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
    try w.print("  root:      {s}\n\n", .{plan.package.project_root});

    try sectionHeading(w, profile, "Lint roots");
    if (plan.lint_roots.len == 0) {
        try w.print("  (none)\n\n", .{});
    } else {
        for (plan.lint_roots) |root| {
            try w.print("  {s}\n", .{root.path});
            try w.print("    mode:    {s}\n", .{@tagName(root.mode)});
            try w.print("    targets: {d}\n", .{root.targetCount()});
            const show = @min(root.targets.len, sample_target_limit);
            for (root.targets[0..show]) |target| {
                try w.print("      - {s}\n", .{target});
            }
            if (root.targets.len > show) {
                try w.print("      ... and {d} more\n", .{root.targets.len - show});
            }
        }
        try w.print("\n", .{});
    }

    try sectionHeading(w, profile, "Excluded dependencies");
    if (plan.excluded_dependency_roots.len == 0) {
        try w.print("  (none; use --lint-dependencies to include path dependencies)\n\n", .{});
    } else {
        for (plan.excluded_dependency_roots) |dep| {
            try w.print("  - {s}\n", .{dep});
        }
        try w.print("  Skipped unless --lint-dependencies is set.\n\n", .{});
    }

    try sectionHeading(w, profile, "Build script (best effort)");
    if (build_scan_result) |scan| {
        if (scan.dependencies.len > 0) {
            try w.print("  dependencies:\n", .{});
            for (scan.dependencies) |dep| try w.print("    - {s}\n", .{dep});
        }
        if (scan.root_sources.len > 0) {
            try w.print("  root_source_file:\n", .{});
            for (scan.root_sources) |src| try w.print("    - {s}\n", .{src});
        }
        if (scan.dependencies.len == 0 and scan.root_sources.len == 0) {
            try w.print("  (no patterns matched)\n", .{});
        }
        try w.print("  Heuristic scan only; manifest .paths / .dependencies drive lint targeting.\n\n", .{});
    } else {
        try w.print("  (build.zig not found or unreadable)\n\n", .{});
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

    if (no_scan) {
        try carnaval.Style.init().dimmed().renderWithProfile(
            "Scan skipped (--no-scan). Run without it for diagnostic counts.\n",
            w,
            profile,
        );
        try w.flush();
        return;
    }

    try sectionHeading(w, profile, "Scan summary");

    var summary: docent.output.Summary = .{};
    var rule_counts = RuleCounts.init();

    for (plan.lint_roots) |root| {
        for (root.targets) |path| {
            var result = docent.lintFile(allocator, io, path, rule_set) catch continue;
            defer result.deinit();

            for (result.diagnostics.items) |d| {
                summary.observe(d);
                rule_counts.observe(d);
            }
        }
    }

    try w.print("  errors:   {d}\n", .{summary.errors});
    try w.print("  warnings: {d}\n\n", .{summary.warnings});

    var any_rule_output = false;
    inline for (@typeInfo(docent.RuleSet).@"struct".fields) |f| {
        const c = rule_counts.get(f.name);
        if (c.errors > 0 or c.warnings > 0) {
            any_rule_output = true;
            try w.print("  {s}: {d} error(s), {d} warning(s)\n", .{ f.name, c.errors, c.warnings });
        }
    }
    if (!any_rule_output) {
        try w.print("  (no diagnostics)\n", .{});
    }

    try w.print("\n", .{});
    try carnaval.Style.init().dimmed().renderWithProfile(
        "Run `docent` to enforce severities. `docent status` always exits 0 when the report completes.\n",
        w,
        profile,
    );
    try w.flush();
}

const RuleCounts = struct {
    counts: [@typeInfo(docent.RuleSet).@"struct".fields.len]Count,

    const Count = struct {
        errors: usize = 0,
        warnings: usize = 0,
    };

    fn init() RuleCounts {
        return .{ .counts = [_]Count{.{}} ** @typeInfo(docent.RuleSet).@"struct".fields.len };
    }

    fn observe(self: *RuleCounts, d: docent.Diagnostic) void {
        const idx = findRuleIndex(d.rule) orelse return;
        if (d.severity.isError()) {
            self.counts[idx].errors += 1;
        } else if (d.severity == .warn) {
            self.counts[idx].warnings += 1;
        }
    }

    fn get(self: RuleCounts, name: []const u8) Count {
        const idx = findRuleIndex(name) orelse return .{};
        return self.counts[idx];
    }

    fn findRuleIndex(name: []const u8) ?usize {
        inline for (@typeInfo(docent.RuleSet).@"struct".fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) return i;
        }
        return null;
    }
};

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
