//! Shared target flags and helpers for `docent check` subcommands.

const std = @import("std");

const carnaval = @import("carnaval");
const docent = @import("docent");
const fangz = @import("fangz");

const cli_types = @import("types.zig");

pub const TargetArgs = struct {
    positionals: []const []const u8 = &.{},
    config_path: ?[]const u8 = null,
    lib: bool = false,
    bins: bool = false,
    bin: []const []const u8 = &.{},
    tests: bool = false,
    @"test": []const []const u8 = &.{},
    deps: bool = false,
    build_script: bool = false,
    format: cli_types.OutputMode = .pretty,
    fail_fast: cli_types.FailFast = cli_types.default_fail_fast,
};

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
        .brief = "Path to docent.toml",
        .description = "When omitted, Docent searches upward from the working directory for `.config/docent.toml`.",
        .value_hint = "PATH",
        .persistent = options.persistent,
    });

    try cmd.addFlag(bool, .{
        .name = "lib",
        .brief = "Analyze library targets only (default)",
        .default = false,
        .persistent = options.persistent,
    });

    try cmd.addFlag(bool, .{
        .name = "bins",
        .brief = "Analyze all binary targets",
        .default = false,
        .persistent = options.persistent,
    });

    try cmd.addFlag([]const []const u8, .{
        .name = "bin",
        .brief = "Analyze specific binary by name (repeatable)",
        .persistent = options.persistent,
    });

    try cmd.addFlag(bool, .{
        .name = "tests",
        .brief = "Analyze all test targets",
        .default = false,
        .persistent = options.persistent,
    });

    try cmd.addFlag([]const []const u8, .{
        .name = "test",
        .brief = "Analyze specific test by name (repeatable)",
        .persistent = options.persistent,
    });

    try cmd.addFlag(bool, .{
        .name = "deps",
        .brief = "Also analyze files under path dependencies from build.zig.zon",
        .default = false,
        .persistent = options.persistent,
    });

    try cmd.addFlag(bool, .{
        .name = "build-script",
        .brief = "Include the build script module and everything it depends on to be analyzed",
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

pub fn failFastMatches(ff: cli_types.FailFast, severity_level: docent.SeverityLevel) bool {
    return switch (ff) {
        .none => false,
        .@"error" => severity_level.isError(),
        .warn => severity_level == .warn,
        .any => severity_level == .warn or severity_level.isError(),
    };
}

pub fn textFormat(mode: cli_types.OutputMode) docent.output.TextFormat {
    return switch (mode) {
        .pretty => .pretty,
        .minimal => .minimal,
        .json => unreachable,
    };
}

pub fn allocPathDisplayRoot(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const manifest = docent.manifest.findNearestManifestPath(allocator, io) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return realPathFileAlloc(allocator, io, "."),
    };
    defer allocator.free(manifest);
    const dir = std.fs.path.dirname(manifest) orelse return realPathFileAlloc(allocator, io, ".");
    return realPathFileAlloc(allocator, io, dir);
}

fn realPathFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

pub fn printCheckResults(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: TargetArgs,
    summary_label: []const u8,
    diagnostics: []const docent.Diagnostic,
    summary: docent.output.Summary,
    path_display_root: ?[]const u8,
) !void {
    if (args.format == .json) {
        try docent.output.printJsonStdout(io, allocator, diagnostics);
        return;
    }

    const text_options = docent.output.stderrTextOptions(io, textFormat(args.format), .auto, path_display_root);
    try docent.output.printDiagnosticsStderr(io, diagnostics, text_options);
    const had_diagnostics = summary.errors > 0 or summary.warnings > 0;
    try docent.output.printSummaryStderr(io, summary, docent.output.stderrSummaryOptions(io, summary_label, .auto), had_diagnostics);
}

pub fn gatherPlan(allocator: std.mem.Allocator, io: std.Io, args: TargetArgs) !docent.status_plan.Plan {
    return docent.status_plan.gather(allocator, io, .{
        .lib = args.lib,
        .bins = args.bins,
        .bin_names = args.bin,
        .tests = args.tests,
        .test_names = args.@"test",
        .deps = args.deps,
        .build_script = args.build_script,
        .positionals = args.positionals,
    });
}

pub fn printStderr(io: std.Io, comptime fmt: []const u8, fmt_args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    try stderr.interface.print(fmt, fmt_args);
    try stderr.interface.flush();
}

pub const RuleCategory = enum {
    doc,
    style,
    complexity,

    pub fn heading(self: RuleCategory) []const u8 {
        return switch (self) {
            .doc => "Documentation comments",
            .style => "Style",
            .complexity => "Complexity",
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
        };
        for (doc_rules) |name| {
            if (std.mem.eql(u8, rule, name)) return .doc;
        }
        if (std.mem.eql(u8, rule, "identifier_case") or std.mem.eql(u8, rule, "line_length_limit")) return .style;
        const complexity_rules = [_][]const u8{
            "cognitive_complexity",
            "cyclomatic_complexity",
            "max_fun_params",
        };
        for (complexity_rules) |name| {
            if (std.mem.eql(u8, rule, name)) return .complexity;
        }
        return null;
    }
};

pub const RuleCountRow = struct {
    category: RuleCategory,
    severity: docent.SeverityLevel,
    rule: []const u8,
    count: usize,
};

pub fn appendDiagnosticCounts(
    allocator: std.mem.Allocator,
    diagnostics: []const docent.Diagnostic,
    rows: *std.ArrayList(RuleCountRow),
) !void {
    for (diagnostics) |d| {
        if (!d.severity_level.isActive()) continue;
        const category = RuleCategory.fromRule(d.rule) orelse continue;

        var matched = false;
        for (rows.items) |*row| {
            if (row.category == category and row.severity == d.severity_level and std.mem.eql(u8, row.rule, d.rule)) {
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
    const tty_config = std.Io.Terminal.Mode.detect(io, std.Io.File.stderr(), false, false) catch .no_color;
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
    const count_text = try std.fmt.bufPrint(&count_buf, "{d}", .{row.count});
    try carnaval.Style.init().bolded().renderWithProfile(count_text, &aw.writer, profile);
    try aw.writer.writeAll(" ");
    try docent.output.writeSeverityRuleTag(&aw.writer, row.severity, row.rule, profile);

    return aw.toOwnedSlice();
}

fn printCategoryHeading(writer: *std.Io.Writer, profile: carnaval.ColorProfile, title: []const u8) !void {
    try carnaval.Style.init().bolded().renderWithProfile(title, writer, profile);
    try writer.writeAll("\n");
}

pub fn printCategorizedEffectiveRules(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    profile: carnaval.ColorProfile,
    rule_set: docent.RuleSeverities,
) !void {
    var any_category = false;
    try printEffectiveRulesCategory(allocator, w, profile, rule_set, .doc, &any_category);
    try printEffectiveRulesCategory(allocator, w, profile, rule_set, .style, &any_category);
    try printEffectiveRulesCategory(allocator, w, profile, rule_set, .complexity, &any_category);

    if (!any_category) {
        try carnaval.Style.init().dimmed().renderWithProfile("  (none)\n", w, profile);
    }
}

fn printEffectiveRulesCategory(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    profile: carnaval.ColorProfile,
    rule_set: docent.RuleSeverities,
    comptime category: RuleCategory,
    any_category: *bool,
) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    inline for (@typeInfo(docent.RuleSeverities).@"struct".fields) |field| {
        comptime {
            const rule_category = RuleCategory.fromRule(field.name) orelse continue;
            if (rule_category != category) continue;
        }

        const level = @field(rule_set, field.name);
        var buf: [512]u8 = undefined;
        var line_writer = std.Io.Writer.fixed(&buf);
        try docent.output.writeSeverityRuleTag(&line_writer, level, field.name, profile);
        try lines.append(allocator, try allocator.dupe(u8, line_writer.buffered()));
    }

    if (lines.items.len == 0) return;

    if (any_category.*) try w.writeAll("\n");
    try printCategoryHeading(w, profile, category.heading());
    try carnaval.renderList(lines.items, w, .{
        .style = .bullet,
        .indent = "  ",
        .color_profile = profile,
    });
    any_category.* = true;
}

pub fn printCategorizedSummary(allocator: std.mem.Allocator, io: std.Io, rows: []const RuleCountRow) !void {
    const profile = stderrColorProfile(io);
    const categories = [_]RuleCategory{ .doc, .style, .complexity };

    var buf: [8192]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    const writer = &stderr.interface;

    var any_category = false;

    for (categories) |category| {
        var lines: std.ArrayList([]const u8) = .empty;
        defer {
            for (lines.items) |line| allocator.free(line);
            lines.deinit(allocator);
        }

        for (rows) |row| {
            if (row.category != category) continue;
            try lines.append(allocator, try formatSummaryLine(allocator, row, profile));
        }

        if (lines.items.len == 0) continue;

        if (any_category) try writer.writeAll("\n");
        try printCategoryHeading(writer, profile, category.heading());
        try carnaval.renderList(lines.items, writer, .{
            .style = .bullet,
            .indent = "  ",
            .color_profile = profile,
        });
        try writer.writeAll("\n");
        any_category = true;
    }

    if (!any_category) {
        try carnaval.Style.init().dimmed().renderWithProfile("No issues found.\n", writer, profile);
    }

    try writer.flush();
}
