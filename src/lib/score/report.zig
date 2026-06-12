//! Aggregates individual score checks into a Go Report Card-style report.

const std = @import("std");

const status_plan = @import("../status_plan.zig");
const RuleSeverities = @import("../RuleSeverities.zig");
const config = @import("../config.zig");

const community = @import("community.zig");
const format = @import("format.zig");
const grade = @import("grade.zig");
const legal = @import("legal.zig");
const lint = @import("lint.zig");

pub const Check = struct {
    name: []const u8,
    description: []const u8,
    weight: f64,
    percentage: f64,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *Check, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.error_message) |msg| allocator.free(msg);
        self.* = .{
            .name = "",
            .description = "",
            .weight = 0,
            .percentage = 0,
        };
    }
};

pub const Report = struct {
    checks: []Check = &.{},
    average: f64 = 0,
    grade: grade.Grade = .f,
    files: usize = 0,
    issues: usize = 0,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.checks) |*check| check.deinit(allocator);
        allocator.free(self.checks);
        self.* = .{};
    }
};

pub const Options = struct {
    plan: *const status_plan.Plan,
    rule_set: RuleSeverities,
    config_path: ?[]const u8 = null,
    format_paths: []const []const u8 = &.{},
};

fn appendCheck(
    allocator: std.mem.Allocator,
    checks: *std.ArrayList(Check),
    name: []const u8,
    description: []const u8,
    weight: f64,
    percentage_value: f64,
    error_message: ?[]const u8,
) !void {
    try checks.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .weight = weight,
        .percentage = percentage_value,
        .error_message = if (error_message) |msg| try allocator.dupe(u8, msg) else null,
    });
}

fn collectFormatPaths(allocator: std.mem.Allocator, plan: *const status_plan.Plan, explicit: []const []const u8) ![]const []const u8 {
    if (explicit.len > 0) {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |path| allocator.free(path);
            out.deinit(allocator);
        }
        for (explicit) |path| try out.append(allocator, try allocator.dupe(u8, path));
        return try out.toOwnedSlice(allocator);
    }

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }

    try out.append(allocator, try allocator.dupe(u8, plan.package.project_root));
    return try out.toOwnedSlice(allocator);
}

/// Builds a weighted score report for `options.plan`.
pub fn gather(allocator: std.mem.Allocator, io: std.Io, options: Options) !Report {
    var checks: std.ArrayList(Check) = .empty;
    errdefer {
        for (checks.items) |*check| check.deinit(allocator);
        checks.deinit(allocator);
    }

    var issues: usize = 0;
    var files: usize = 0;

    const format_paths = try collectFormatPaths(allocator, options.plan, options.format_paths);
    defer {
        for (format_paths) |path| allocator.free(path);
        allocator.free(format_paths);
    }

    var format_report = try format.check(allocator, io, format_paths);
    defer format_report.deinit(allocator);
    files += format_report.total_files;
    issues += format_report.failed_files.len;
    try appendCheck(allocator, &checks, "zigfmt", "Code is formatted with `zig fmt`", 1.0, format.percentage(format_report), format_report.error_message);

    var legal_report = try legal.scan(allocator, io, options.plan.package.project_root);
    defer legal_report.deinit(allocator);
    try appendCheck(allocator, &checks, "license", "Project has a LICENSE file", 0.5, legal.percentage(legal_report), null);

    var community_report = try community.scan(allocator, io, options.plan.package.project_root);
    defer community_report.deinit(allocator);
    try appendCheck(allocator, &checks, "readme", "Project has a README file", 0.5, community.percentage(community_report), null);

    const lint_options = lint.loadOptionsFromConfig(allocator, io, options.config_path);
    var lint_report = try lint.scorePlan(
        allocator,
        io,
        options.plan,
        lint_options.docs,
        lint_options.style,
        lint_options.complexity,
    );
    defer lint_report.deinit(allocator);
    for (lint_report.categories) |category| {
        files += category.total_files;
        issues += category.issue_count;
        const pct = lint.percentage(category);
        try appendCheck(allocator, &checks, category.category.label(), switch (category.category) {
            .docs => "Documentation comments meet project rules",
            .style => "Naming and style rules pass",
            .complexity => "Complexity rules pass",
        }, 1.0, pct, null);
    }

    var weighted_sum: f64 = 0;
    var weight_total: f64 = 0;
    for (checks.items) |check| {
        weighted_sum += check.percentage * check.weight;
        weight_total += check.weight;
    }
    const average = if (weight_total > 0) weighted_sum / weight_total else 100.0;

    const out_checks = try checks.toOwnedSlice(allocator);
    return .{
        .checks = out_checks,
        .average = average,
        .grade = grade.fromPercentage(average),
        .files = files,
        .issues = issues,
    };
}
