const std = @import("std");

pub const WarningMode = enum {
    /// Show lizard's default report, including the general summary.
    summary,
    /// Show only warnings using lizard's default Clang-style warning format.
    warnings_only,
    /// Show only warnings using Microsoft Visual Studio-style warning format.
    warnings_msvs,
};

pub const Options = struct {
    /// Executable name or path used to invoke lizard.
    lizard_path: []const u8 = "lizard",
    /// Cyclomatic complexity warning threshold passed as `--CCN`.
    ccn: usize = 10,
    /// Function length warning threshold passed as `--length`.
    length: usize = 80,
    /// Argument count warning threshold passed as `--arguments`.
    arguments: usize = 7,
    /// When true, only analyze files changed from source control.
    modified: bool = true,
    warning_mode: WarningMode = .warnings_only,
    /// Lizard extensions to enable. Each item is emitted as a repeated `--extension` flag.
    extensions: []const []const u8 = &.{"NS"},
    /// Considering src as the sanest default since that's what Zig defaults to on `zig init`.
    paths: []const []const u8 = &.{"src"},
    /// No excluded paths by default, since considering the source directory is usually enough to not include the tests, modules, etc.
    excluded_paths: []const []const u8 = &.{},
    step_name: []const u8 = "lizzy",
    step_description: []const u8 = "Run lizard checks.",
    /// Lizard threshold settings. Each item is emitted as a repeated `--Threshold` flag.
    thresholds: []const []const u8 = &.{"max_nested_structures=4"},
};

pub fn addStep(b: *std.Build, options: Options) *std.Build.Step {
    const lizard = b.addSystemCommand(&.{options.lizard_path});
    lizard.addArgs(&.{
        "--languages",
        "zig",
        "--CCN",
        b.fmt("{d}", .{options.ccn}),
        "--length",
        b.fmt("{d}", .{options.length}),
        "--arguments",
        b.fmt("{d}", .{options.arguments}),
    });

    if (options.modified) lizard.addArg("--modified");

    switch (options.warning_mode) {
        .summary => {},
        .warnings_only => lizard.addArg("--warnings_only"),
        .warnings_msvs => lizard.addArg("--warning-msvs"),
    }

    for (options.extensions) |extension| {
        lizard.addArg("--extension");
        lizard.addArg(extension);
    }

    for (options.thresholds) |threshold| {
        lizard.addArg("--Threshold");
        lizard.addArg(threshold);
    }

    for (options.excluded_paths) |path| {
        lizard.addArg("--exclude");
        lizard.addArg(path);
    }

    lizard.addArgs(options.paths);

    const step = b.step(
        options.step_name,
        options.step_description,
    );
    step.dependOn(&lizard.step);

    return step;
}

fn optionsFromBuild(b: *std.Build) Options {
    return .{
        .lizard_path = b.option([]const u8, "lizard-path", "Executable name or path used to invoke lizard") orelse "lizard",
        .ccn = b.option(usize, "ccn", "Cyclomatic complexity warning threshold") orelse 10,
        .length = b.option(usize, "length", "Function length warning threshold") orelse 80,
        .arguments = b.option(usize, "arguments", "Argument count warning threshold") orelse 7,
        .modified = b.option(bool, "modified", "Only analyze files changed from source control") orelse true,
        .warning_mode = b.option(WarningMode, "warning-mode", "Warning output mode") orelse .warnings_only,
        .extensions = stringListOption(b, "extensions", "Comma-separated lizard extensions to enable", &.{"NS"}),
        .paths = stringListOption(b, "paths", "Comma-separated paths to analyze", &.{"src"}),
        .excluded_paths = stringListOption(b, "excluded-paths", "Comma-separated paths or patterns to exclude", &.{}),
        .thresholds = stringListOption(b, "thresholds", "Comma-separated lizard threshold settings", &.{"max_nested_structures=4"}),
    };
}

fn stringListOption(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    default: []const []const u8,
) []const []const u8 {
    const value = b.option([]const u8, name, description) orelse return default;
    if (value.len == 0) return &.{};

    var max_items: usize = 1;
    for (value) |c| {
        if (c == ',') max_items += 1;
    }

    const items = b.allocator.alloc([]const u8, max_items) catch @panic("OOM");
    var item_count: usize = 0;
    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |raw_item| {
        const item = std.mem.trim(u8, raw_item, " \t\r\n");
        if (item.len == 0) continue;

        items[item_count] = item;
        item_count += 1;
    }

    return items[0..item_count];
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("lizzy", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = mod;

    _ = addStep(b, optionsFromBuild(b));
}
