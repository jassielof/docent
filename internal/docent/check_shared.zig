//! Shared target flags and helpers for `docent check` subcommands.

const std = @import("std");

const carnaval = @import("carnaval");
const fangz = @import("fangz");
const rules = @import("rules");
const Diagnostic = rules.Diagnostic;
const RuleSeverities = rules.RuleSeverities;
const SeverityLevel = rules.SeverityLevel;

const config = @import("config.zig");
const manifest = @import("manifest.zig");
const output = @import("output.zig");
const Config = @import("schemas/Config.zig");
const status_plan = @import("status_plan.zig");
const cli_types = @import("types.zig");

pub const TargetArgs = struct {
    positionals: []const []const u8 = &.{},
    config_path: ?[]const u8 = null,
    manifest_path: ?[]const u8 = null,
    deps: bool = false,
    format: cli_types.OutputMode = .pretty,
    fail_fast: cli_types.FailFast = cli_types.default_fail_fast,
};

/// CLI paths override `[check].include`; configured includes extend manifest paths unless disabled.
pub fn gatherPlan(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: TargetArgs,
) !status_plan.Plan {
    var cfg: Config = config.loadConfigFromCli(
        allocator,
        io,
        args.config_path,
    ) catch .{};
    defer cfg.deinit(allocator);

    const resolved_manifest = try resolveManifestPath(
        allocator,
        io,
        args.manifest_path,
    );
    defer if (resolved_manifest) |p| allocator.free(p);

    return status_plan.gather(
        allocator,
        io,
        .{
            .deps = args.deps,
            .dependency_paths_only = args.deps,
            .positionals = if (args.deps) &.{} else if (args.positionals.len > 0) args.positionals else cfg.check.include,
            .inherit_manifest_paths = !args.deps and args.positionals.len == 0 and cfg.check.inherit_manifest,
            .exclude_paths = cfg.check.exclude,
            .manifest_path = resolved_manifest,
        },
    );
}

pub const RegisterTargetFlagsOptions = struct {
    /// When true, flags are inherited by category subcommands (register on `check` only).
    persistent: bool = false,
    /// When true, registers the variadic `paths` positional (category subcommands only).
    positionals: bool = true,
};

pub fn registerTargetFlags(cmd: *fangz.Command, options: RegisterTargetFlagsOptions) !void {
    if (options.positionals) {
        try cmd.addPositional(.{
            .name = "paths",
            .brief = "Files or directories to analyze. If omitted, uses package paths from build.zig.zon when available.",
            .variadic = true,
        });
    }

    try cmd.addFlag(?[]const u8, .{
        .name = "config-path",
        .brief = "Path to a docent.toml configuration file",
        .description = "Must point to a file, not a directory. When omitted, Docent searches upward from the working directory for `.config/docent.toml`.",
        .value_hint = "FILE",
        .persistent = options.persistent,
    });

    try cmd.addFlag(?[]const u8, .{
        .name = "manifest-path",
        .brief = "Path to a build.zig.zon manifest or its parent directory",
        .description = "Operates as if Docent were invoked from the manifest's directory. Accepts the manifest file directly or a directory containing it. When omitted, searches upward from the working directory.",
        .value_hint = "PATH",
        .persistent = options.persistent,
    });

    try cmd.addFlag(bool, .{
        .name = "deps",
        .brief = "Analyze local path dependencies from build.zig.zon (.path entries only, not URL-based)",
        .default = false,
        .persistent = options.persistent,
    });
}

/// Registers the variadic `paths` positional on a category subcommand.
pub fn registerCategoryPositionals(cmd: *fangz.Command) !void {
    try cmd.addPositional(.{
        .name = "paths",
        .brief = "Files or directories to analyze. If omitted, uses package paths from build.zig.zon when available.",
        .variadic = true,
    });
}

pub fn registerOutputFlags(cmd: *fangz.Command) !void {
    try cmd.addFlag(cli_types.OutputMode, .{
        .name = "format",
        .short = 'f',
        .brief = "Output format",
        .value_hint = "FORMAT",
        .default = .pretty,
        .allowed_values_style = .comma,
    });

    try cmd.addFlag(cli_types.FailFast, .{
        .name = "fail-fast",
        .short = 'F',
        .brief = "Stop after the first matching severity",
        .value_hint = "WHEN",
        .default = cli_types.default_fail_fast,
    });
}

pub fn failFastMatches(ff: cli_types.FailFast, severity_level: SeverityLevel) bool {
    return switch (ff) {
        .none => false,
        .@"error" => severity_level.isError(),
        .warn => severity_level == .warn,
        .any => severity_level == .warn or severity_level.isError(),
    };
}

pub fn textFormat(mode: cli_types.OutputMode) output.TextFormat {
    return switch (mode) {
        .pretty => .pretty,
        .minimal => .minimal,
        .json => unreachable,
    };
}

pub fn allocPathDisplayRoot(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const manifest_path = manifest.findNearestManifestPath(allocator, io) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return realPathFileAlloc(
            allocator,
            io,
            ".",
        ),
    };
    defer allocator.free(manifest_path);
    const dir = std.fs.path.dirname(manifest_path) orelse return realPathFileAlloc(
        allocator,
        io,
        ".",
    );
    return realPathFileAlloc(
        allocator,
        io,
        dir,
    );
}

fn realPathFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(
        io,
        path,
        &buffer,
    );
    return allocator.dupe(u8, buffer[0..len]);
}

pub fn printCheckResults(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: TargetArgs,
    summary_label: []const u8,
    diagnostics: []const Diagnostic,
    summary: output.Summary,
    path_display_root: ?[]const u8,
    options: PrintCheckResultsOptions,
) !void {
    if (args.format == .json) {
        try output.printJsonStdout(
            io,
            allocator,
            diagnostics,
        );
        return;
    }

    var text_options = output.stdoutTextOptions(
        io,
        textFormat(args.format),
        .auto,
        path_display_root,
    );
    text_options.minimal_primary_label = options.minimal_primary_label;
    try output.printDiagnosticsStdout(
        io,
        diagnostics,
        text_options,
    );
    const had_diagnostics = summary.errors > 0 or summary.warnings > 0;
    try output.printSummaryStdout(
        io,
        summary,
        output.stdoutSummaryOptions(
            io,
            summary_label,
            .auto,
        ),
        had_diagnostics,
    );

    if (options.categorized_summary and had_diagnostics) {
        var rows: std.ArrayList(RuleCountRow) = .empty;
        defer rows.deinit(allocator);
        try appendDiagnosticCounts(
            allocator,
            diagnostics,
            &rows,
        );
        try printCategorizedSummaryStdout(
            allocator,
            io,
            rows.items,
        );
    }
}

pub const PrintCheckResultsOptions = struct {
    /// In minimal mode, show a diagnostic's compact result instead of its rule
    /// ID. Use only when the invoking subcommand already identifies the rule.
    minimal_primary_label: bool = false,
    /// Follow the overall total with counts grouped by category and rule.
    categorized_summary: bool = false,
};

fn resolveManifestPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    raw: ?[]const u8,
) !?[]u8 {
    const path = raw orelse return null;

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = std.Io.Dir.cwd().realPathFile(
        io,
        path,
        &buffer,
    ) catch
        return error.FileNotFound;
    const abs = buffer[0..abs_len];

    if (std.mem.endsWith(
        u8,
        abs,
        "build.zig.zon",
    )) {
        return try allocator.dupe(u8, abs);
    }

    const candidate = try std.fs.path.join(allocator, &.{ abs, "build.zig.zon" });
    const stat = std.Io.Dir.cwd().statFile(
        io,
        candidate,
        .{},
    ) catch {
        allocator.free(candidate);
        return error.FileNotFound;
    };
    _ = stat;
    return candidate;
}

pub fn printStderr(
    io: std.Io,
    comptime fmt: []const u8,
    fmt_args: anytype,
) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    try stderr.interface.print(fmt, fmt_args);
    try stderr.interface.flush();
}

pub const RuleCategory = enum {
    doc,
    style,
    complexity,
    size,

    pub fn heading(self: RuleCategory) []const u8 {
        return switch (self) {
            .doc => "Documentation comments",
            .style => "Style",
            .complexity => "Complexity",
            .size => "Size",
        };
    }

    pub fn fromRule(rule: []const u8) ?RuleCategory {
        const doc_rules = [_][]const u8{
            "missing_doc_comment",
            "missing_doctest",
            "private_doctest",
            "blank_doc_comment",
            "missing_summary_terminal_punctuation",
            "trailing_blank_doc_comment",
            "doctest_naming_mismatch",
            "invalid_leading_phrase",
            "invalid_boolean_summary",
            "misplaced_doc_comment",
        };
        for (doc_rules) |name| {
            if (std.mem.eql(
                u8,
                rule,
                name,
            )) return .doc;
        }
        if (std.mem.eql(
            u8,
            rule,
            "identifier_case",
        )) return .style;
        if (std.mem.eql(
            u8,
            rule,
            "cognitive_complexity",
        ) or std.mem.eql(
            u8,
            rule,
            "cyclomatic_complexity",
        )) return .complexity;
        if (std.mem.eql(
            u8,
            rule,
            "max_fun_params",
        ) or std.mem.eql(
            u8,
            rule,
            "line_length_limit",
        )) return .size;
        return null;
    }
};

pub const RuleCountRow = struct {
    category: RuleCategory,
    severity: SeverityLevel,
    rule: []const u8,
    count: usize,
};

pub fn appendDiagnosticCounts(
    allocator: std.mem.Allocator,
    diagnostics: []const Diagnostic,
    rows: *std.ArrayList(RuleCountRow),
) !void {
    for (diagnostics) |d| {
        if (!d.severity_level.isActive()) continue;
        const category = RuleCategory.fromRule(d.rule) orelse continue;

        var matched = false;
        for (rows.items) |*row| {
            if (row.category == category and row.severity == d.severity_level and std.mem.eql(
                u8,
                row.rule,
                d.rule,
            )) {
                row.count += 1;
                matched = true;
                break;
            }
        }
        if (matched) continue;

        try rows.append(allocator, .{
            .category = category,
            .severity = d.severity_level,
            .rule = d.rule,
            .count = 1,
        });
    }
}

fn stderrColorProfile(io: std.Io) carnaval.ColorProfile {
    const tty_config = std.Io.Terminal.Mode.detect(
        io,
        std.Io.File.stderr(),
        false,
        false,
    ) catch .no_color;
    const detected = carnaval.colorProfileForHandle(std.Io.File.stderr().handle);
    if (tty_config == .no_color) return .none;
    return if (detected == .none) .ansi16 else detected;
}

fn formatSummaryLine(
    allocator: std.mem.Allocator,
    row: RuleCountRow,
    profile: carnaval.ColorProfile,
) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    errdefer aw.deinit();

    var count_buf: [32]u8 = undefined;
    const count_text = try std.fmt.bufPrint(
        &count_buf,
        "{d}",
        .{row.count},
    );
    try carnaval.Style.init().bolded().renderWithProfile(
        count_text,
        &aw.writer,
        profile,
    );
    try aw.writer.writeAll(" ");
    try output.writeSeverityRuleTag(
        &aw.writer,
        row.severity,
        row.rule,
        profile,
    );

    return aw.toOwnedSlice();
}

fn printCategoryHeading(
    writer: *std.Io.Writer,
    profile: carnaval.ColorProfile,
    title: []const u8,
) !void {
    try carnaval.Style.init().italicized().renderWithProfile(
        title,
        writer,
        profile,
    );
    try writer.writeAll("\n");
}

pub fn printCategorizedEffectiveRules(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    profile: carnaval.ColorProfile,
    rule_set: RuleSeverities,
) !void {
    var any_category = false;
    try printEffectiveRulesCategory(
        allocator,
        w,
        profile,
        rule_set,
        .doc,
        &any_category,
    );
    try printEffectiveRulesCategory(
        allocator,
        w,
        profile,
        rule_set,
        .style,
        &any_category,
    );
    try printEffectiveRulesCategory(
        allocator,
        w,
        profile,
        rule_set,
        .complexity,
        &any_category,
    );
    try printEffectiveRulesCategory(
        allocator,
        w,
        profile,
        rule_set,
        .size,
        &any_category,
    );

    if (!any_category) {
        try carnaval.Style.init().dimmed().renderWithProfile(
            "  (none)\n",
            w,
            profile,
        );
    }
}

fn printEffectiveRulesCategory(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    profile: carnaval.ColorProfile,
    rule_set: RuleSeverities,
    comptime category: RuleCategory,
    any_category: *bool,
) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    inline for (@typeInfo(RuleSeverities).@"struct".fields) |field| {
        comptime {
            const rule_category = RuleCategory.fromRule(field.name) orelse continue;
            if (rule_category != category) continue;
        }

        const level = @field(rule_set, field.name);
        var buf: [512]u8 = undefined;
        var line_writer = std.Io.Writer.fixed(&buf);
        try output.writeSeverityRuleTag(
            &line_writer,
            level,
            field.name,
            profile,
        );
        try lines.append(allocator, try allocator.dupe(u8, line_writer.buffered()));
    }

    if (lines.items.len == 0) return;

    if (any_category.*) try w.writeAll("\n");
    try printCategoryHeading(
        w,
        profile,
        category.heading(),
    );
    try carnaval.renderList(
        lines.items,
        w,
        .{
            .style = .bullet,
            .indent = "  ",
            .marker_style = .{},
            .item_style = .{},
            .color_profile = profile,
        },
    );
    any_category.* = true;
}

pub fn printCategorizedSummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    rows: []const RuleCountRow,
) !void {
    const profile = stderrColorProfile(io);
    var buf: [8192]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    try writeCategorizedSummary(
        allocator,
        &stderr.interface,
        profile,
        rows,
    );
    try stderr.interface.flush();
}

fn printCategorizedSummaryStdout(
    allocator: std.mem.Allocator,
    io: std.Io,
    rows: []const RuleCountRow,
) !void {
    const tty_config = std.Io.Terminal.Mode.detect(
        io,
        std.Io.File.stdout(),
        false,
        false,
    ) catch .no_color;
    const detected = carnaval.colorProfileForHandle(std.Io.File.stdout().handle);
    const profile = if (tty_config == .no_color)
        carnaval.ColorProfile.none
    else if (detected == .none)
        carnaval.ColorProfile.ansi16
    else
        detected;

    var buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try stdout.interface.writeAll("\nFindings by category\n");
    try writeCategorizedSummary(
        allocator,
        &stdout.interface,
        profile,
        rows,
    );
    try stdout.interface.flush();
}

fn writeCategorizedSummary(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    profile: carnaval.ColorProfile,
    rows: []const RuleCountRow,
) !void {
    const categories = [_]RuleCategory{
        .doc,
        .style,
        .complexity,
        .size,
    };

    var any_category = false;

    for (categories) |category| {
        var lines: std.ArrayList([]const u8) = .empty;
        defer {
            for (lines.items) |line| allocator.free(line);
            lines.deinit(allocator);
        }

        for (rows) |row| {
            if (row.category != category) continue;
            try lines.append(allocator, try formatSummaryLine(
                allocator,
                row,
                profile,
            ));
        }

        if (lines.items.len == 0) continue;

        if (any_category) try writer.writeAll("\n");
        try printCategoryHeading(
            writer,
            profile,
            category.heading(),
        );
        try carnaval.renderList(
            lines.items,
            writer,
            .{
                .style = .bullet,
                .indent = "  ",
                .marker_style = .{},
                .item_style = .{},
                .color_profile = profile,
            },
        );
        try writer.writeAll("\n");
        any_category = true;
    }

    if (!any_category) {
        try carnaval.Style.init().dimmed().renderWithProfile(
            "No issues found.\n",
            writer,
            profile,
        );
    }
}

test "categorized summary groups rule counts under their categories" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &out);
    defer writer.deinit();

    const rows = [_]RuleCountRow{
        .{ .category = .complexity, .severity = .warn, .rule = "cognitive_complexity", .count = 3 },
        .{ .category = .complexity, .severity = .warn, .rule = "cyclomatic_complexity", .count = 5 },
        .{ .category = .size, .severity = .deny, .rule = "max_fun_params", .count = 1 },
    };
    try writeCategorizedSummary(
        std.testing.allocator,
        &writer.writer,
        .none,
        &rows,
    );
    out = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(
        u8,
        out.items,
        "Complexity\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.items,
        "3 warning[cognitive_complexity]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.items,
        "5 warning[cyclomatic_complexity]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.items,
        "Size\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.items,
        "1 error[max_fun_params]",
    ) != null);
}
