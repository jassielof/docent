//! Lint category scores derived from Docent diagnostics.

const std = @import("std");

const RuleSeverities = @import("../RuleSeverities.zig");
const status_plan = @import("../status_plan.zig");
const targeting = @import("../targeting.zig");
const root = @import("../root.zig");
const rules = @import("../rules.zig");
const config = @import("../config.zig");

pub const Category = enum {
    doc,
    style,
    complexity,

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .doc => "documentation",
            .style => "style",
            .complexity => "complexity",
        };
    }

    fn rules(self: Category) []const []const u8 {
        return switch (self) {
            .doc => &.{
                "missing_doc_comment",
                "missing_doctest",
                "private_doctest",
                "blank_doc_comment",
                "missing_summary_terminal_punctuation",
                "trailing_blank_doc_comment",
                "doctest_naming_mismatch",
                "invalid_leading_phrase",
            },
            .style => &.{
                "identifier_case",
                "line_length_limit",
            },
            .complexity => &.{
                "cognitive_complexity",
                "cyclomatic_complexity",
                "max_fun_params",
            },
        };
    }
};

pub const CategoryReport = struct {
    category: Category,
    total_files: usize = 0,
    files_with_issues: usize = 0,
    issue_count: usize = 0,
};

pub const Report = struct {
    categories: []CategoryReport = &.{},

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.categories);
        self.* = .{};
    }
};

fn ruleInCategory(category: Category, rule: []const u8) bool {
    for (category.rules()) |name| {
        if (std.mem.eql(u8, name, rule)) return true;
    }
    return false;
}

fn lintFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    category: Category,
    doc_cfg: rules.doc.Doc,
    style_cfg: rules.style.Style,
    complexity_cfg: rules.complexity.Complexity,
    library_entry_roots: []const []const u8,
    module_name: ?[]const u8,
) !?usize {
    var result = switch (category) {
        .doc => root.lintFile(allocator, io, path, .{
            .module_name = module_name,
        }, library_entry_roots, doc_cfg),
        .style => root.lintStyleFile(allocator, io, path, style_cfg),
        .complexity => root.lintComplexityFile(allocator, io, path, complexity_cfg),
    } catch return null;
    defer result.deinit();

    var count: usize = 0;
    for (result.diagnostics.items) |d| {
        if (!d.severity_level.isActive()) continue;
        if (!ruleInCategory(category, d.rule)) continue;
        count += 1;
    }
    return count;
}

/// Scores documentation, style, and complexity lint categories for a lint `plan`.
pub fn scorePlan(
    allocator: std.mem.Allocator,
    io: std.Io,
    plan: *const status_plan.Plan,
    doc_cfg: rules.doc.Doc,
    style_cfg: rules.style.Style,
    complexity_cfg: rules.complexity.Complexity,
) !Report {
    const library_entry_roots_owned = blk: {
        if (plan.path_mode == .recursive) break :blk &.{};
        if (plan.path_mode == .module_root) break :blk plan.module_entry_roots;
        const roots = root.collectLibraryEntryRoots(allocator, io, plan.package.project_root) catch &.{};
        break :blk roots;
    };
    defer if (plan.path_mode == .project) {
        for (library_entry_roots_owned) |root_path| allocator.free(root_path);
        allocator.free(library_entry_roots_owned);
    };

    const module_name = if (plan.path_mode == .project or plan.path_mode == .module_root)
        plan.package.name
    else
        null;

    var seen = targeting.PathSet.init(allocator);
    defer seen.deinit(allocator);

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }

    for (plan.resolved_targets) |rt| {
        if (rt.status != .linted) continue;
        for (rt.files) |path| {
            if (try seen.put(allocator, io, path)) continue;
            try files.append(allocator, try allocator.dupe(u8, path));
        }
    }
    for (plan.extra_lint_files) |path| {
        if (try seen.put(allocator, io, path)) continue;
        try files.append(allocator, try allocator.dupe(u8, path));
    }

    const categories = [_]Category{ .doc, .style, .complexity };
    var reports: [categories.len]CategoryReport = undefined;

    for (categories, 0..) |category, idx| {
        var files_with_issues: usize = 0;
        var issue_count: usize = 0;

        for (files.items) |path| {
            const count = try lintFile(
                allocator,
                io,
                path,
                category,
                doc_cfg,
                style_cfg,
                complexity_cfg,
                library_entry_roots_owned,
                module_name,
            ) orelse continue;
            if (count > 0) {
                files_with_issues += 1;
                issue_count += count;
            }
        }

        reports[idx] = .{
            .category = category,
            .total_files = files.items.len,
            .files_with_issues = files_with_issues,
            .issue_count = issue_count,
        };
    }

    const out = try allocator.alloc(CategoryReport, categories.len);
    @memcpy(out, &reports);
    return .{ .categories = out };
}

pub fn percentage(report: CategoryReport) f64 {
    if (report.total_files == 0) return 100.0;
    const clean = report.total_files - report.files_with_issues;
    return @as(f64, @floatFromInt(clean)) * 100.0 / @as(f64, @floatFromInt(report.total_files));
}

pub fn loadOptionsFromConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
) struct {
    doc: rules.doc.Doc,
    style: rules.style.Style,
    complexity: rules.complexity.Complexity,
} {
    const cfg = config.loadConfigFromCli(allocator, io, config_path) catch return .{
        .doc = rules.doc.Doc.defaults(),
        .style = rules.style.Style.defaults(),
        .complexity = rules.complexity.Complexity.defaults(),
    };
    return .{
        .doc = cfg.doc,
        .style = cfg.style,
        .complexity = cfg.complexity,
    };
}
