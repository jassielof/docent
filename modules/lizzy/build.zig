const std = @import("std");

pub const Options = struct {
    lizard_path: []const u8 = "lizard",
    ccn: usize = 10,
    length: usize = 80,
    arguments: usize = 7,
    modified: bool = true,
    // TODO: Warnings only isn't a boolean, but a weird enum-like boolean, by default, lizard will always show a general summary, and then we can enable if we want only warnings, but lizard can also show these warnings in the style of MSVS, which is called via `--warning-msvs`, so we should allow those options, but by default just show only warnings via `--warnings_only` or `-w` which is its short for the `--warnings_only` (these are LLVM's Clang warnings style)
    warnings_only: bool = true,
    // TODO: Lizard supports many extensions: "cpre", "wordcount", "outside", "IgnoreAssert", and "NS". These are called by repeating the flag, e.g. `--extension cpre --extension wordcount` or via its short flags, e.g. `-Ecpre -Ewordcount`
    extensions: []const []const u8 = &.{"NS"},
    /// Considering src as the sanest default since that's what Zig defaults to on `zig init`
    paths: []const []const u8 = &.{"src"},
    /// No excluded paths by default, since considering the source directory is usually enough to not include the tests, modules, etc.
    excluded_paths: []const []const u8 = &.{},
    step_name: []const u8 = "lizzy",
    step_description: []const u8 = "Run lizard checks.",
    // TODO: This is the same case as extensions, repeated flags.
    thresholds: []const []const u8 = &.{"max_nested_structure=4"},
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
    if (options.warnings_only) lizard.addArg("--warnings_only");

    lizard.addArgs(options.paths);

    const step = b.step(
        options.step_name,
        options.step_description,
    );
    step.dependOn(&lizard.step);

    return step;
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
    const default_options = b.addOptions();
    default_options.addOption([]const u8, "lizard-path", "lizard");
    default_options.addOption(usize, "CCN", 10);
    default_options.addOption(usize, "length", 80);
    default_options.addOption(usize, "arguments", 7);
    default_options.addOption(bool, "modified", true);
    // By
    default_options.addOption(bool, "warnings-only", true);

    default_options.addOption([]const []const u8, "extensions", &.{"NS"});
    default_options.addOption([]const []const u8, "paths", &.{"src"});

    // It's expected that whenever you run the step, your shell recognizes the lizard command.
    const lizard = b.addSystemCommand(&.{"lizard"});
    lizard.addArgs(&.{
        "--languages",
        "zig",
        "--CCN",
        "10",
        "--length",
        "80",
        "--arguments",
        "7",
        "--modified",
        "--warnings_only",
        "--extension",
        "NS",
        "src",
    });
}
