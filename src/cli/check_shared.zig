//! Shared target flags and helpers for `docent check` subcommands.

const std = @import("std");

const docent = @import("docent");
const fangz = @import("fangz");

const cli_flags = @import("flags.zig");

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
};

pub fn registerTargetFlags(cmd: *fangz.Command) !void {
    try cmd.addPositional(.{
        .name = "paths",
        .brief = "Files or directories to analyze. If omitted, uses package paths from build.zig.zon when available.",
        .variadic = true,
    });

    try cli_flags.registerConfigPath(cmd);

    try cmd.addFlag(bool, .{
        .name = "lib",
        .brief = "Analyze library targets only (default)",
        .default = false,
    });

    try cmd.addFlag(bool, .{
        .name = "bins",
        .brief = "Analyze all binary targets",
        .default = false,
    });

    try cmd.addFlag([]const []const u8, .{
        .name = "bin",
        .brief = "Analyze specific binary by name (repeatable)",
    });

    try cmd.addFlag(bool, .{
        .name = "tests",
        .brief = "Analyze all test targets",
        .default = false,
    });

    try cmd.addFlag([]const []const u8, .{
        .name = "test",
        .brief = "Analyze specific test by name (repeatable)",
    });

    try cmd.addFlag(bool, .{
        .name = "deps",
        .brief = "Also analyze files under path dependencies from build.zig.zon",
        .default = false,
    });

    try cmd.addFlag(bool, .{
        .name = "build-script",
        .brief = "Include build.zig and build/*.zig files in targets",
        .default = false,
    });
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
    docs,
    style,
    complexity,

    pub fn heading(self: RuleCategory) []const u8 {
        return switch (self) {
            .docs => "Documentation comments",
            .style => "Style",
            .complexity => "Complexity",
        };
    }

    pub fn fromRule(rule: []const u8) ?RuleCategory {
        const docs_rules = [_][]const u8{
            "missing_doc_comment",
            "missing_doctest",
            "private_doctest",
            "blank_doc_comment",
            "missing_summary_terminal_punctuation",
            "trailing_blank_doc_comment",
            "doctest_naming_mismatch",
            "invalid_leading_phrase",
        };
        for (docs_rules) |name| {
            if (std.mem.eql(u8, rule, name)) return .docs;
        }
        if (std.mem.eql(u8, rule, "identifier_case")) return .style;
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

pub fn printCategorizedSummary(io: std.Io, rows: []const RuleCountRow) !void {
    const categories = [_]RuleCategory{ .docs, .style, .complexity };
    var any_category = false;

    for (categories) |category| {
        var category_has_rows = false;
        var buf: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &buf);

        for (rows) |row| {
            if (row.category != category) continue;
            if (!category_has_rows) {
                if (any_category) try stderr.interface.print("\n", .{});
                try stderr.interface.print("{s}:\n", .{category.heading()});
                category_has_rows = true;
                any_category = true;
            }
            try stderr.interface.print(
                "- {d} {s} [{s}]\n",
                .{ row.count, @tagName(row.severity), row.rule },
            );
        }
        try stderr.interface.flush();
    }

    if (!any_category) {
        try printStderr(io, "No issues found.\n", .{});
    }
}
