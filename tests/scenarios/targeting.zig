//! Scenario: lint target selection, build scripts, and dependency exclusion.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../harness.zig");

test "build scripts are skipped by default" {
    try std.testing.expect(docent.targeting.shouldSkipLintFile("build.zig", .{}));
    try std.testing.expect(docent.targeting.shouldSkipLintFile("build/helpers/steps.zig", .{}));
    try std.testing.expect(!docent.targeting.shouldSkipLintFile("src/lib/root.zig", .{}));
}

test "include_build_scripts overrides default skip" {
    const opts: docent.targeting.Options = .{ .build_script = true };
    try std.testing.expect(!docent.targeting.shouldSkipLintFile("build.zig", opts));
    try std.testing.expect(!docent.targeting.shouldSkipLintFile("build/helpers/steps.zig", opts));
}

test "no-root directories use top-level modules as entrypoints" {
    const dir = try harness.scenarioProjectDir("targeting_multi_module_no_root");
    defer std.testing.allocator.free(dir);

    var files = try docent.targeting.collectDirectoryLintTargets(std.testing.allocator, std.testing.io, dir, .{});
    defer docent.targeting.deinitOwnedPaths(std.testing.allocator, &files);

    var has_re2 = false;
    var has_pcre2 = false;
    var has_re2_api = false;
    var has_pcre2_api = false;
    var has_private_only = false;
    var has_build = false;

    for (files.items) |path| {
        if (std.mem.indexOf(u8, path, "targeting_multi_module_no_root") == null) continue;
        const base = std.fs.path.basename(path);
        if (std.mem.eql(u8, base, "re2.zig")) has_re2 = true;
        if (std.mem.eql(u8, base, "pcre2.zig")) has_pcre2 = true;
        if (std.mem.eql(u8, base, "re2_api.zig")) has_re2_api = true;
        if (std.mem.eql(u8, base, "pcre2_api.zig")) has_pcre2_api = true;
        if (std.mem.eql(u8, base, "private_only.zig")) has_private_only = true;
        if (std.mem.eql(u8, base, "build.zig")) has_build = true;
    }

    try std.testing.expect(has_re2 and has_pcre2 and has_re2_api and has_pcre2_api);
    try std.testing.expect(!has_private_only and !has_build);
}

test "no-root directories include build scripts when enabled" {
    const dir = try harness.scenarioProjectDir("targeting_multi_module_no_root");
    defer std.testing.allocator.free(dir);

    var files = try docent.targeting.collectDirectoryLintTargets(std.testing.allocator, std.testing.io, dir, .{ .build_script = true });
    defer docent.targeting.deinitOwnedPaths(std.testing.allocator, &files);

    var has_build = false;
    for (files.items) |path| {
        if (std.mem.indexOf(u8, path, "targeting_multi_module_no_root") == null) continue;
        if (std.mem.eql(u8, std.fs.path.basename(path), "build.zig")) has_build = true;
    }
    try std.testing.expect(has_build);
}

test "skips files under dependency root from manifest fixture" {
    const dep_file = "tests/fixtures/scenarios/manifest_with_deps/modules/dep/lib.zig";
    const dep_root = "tests/fixtures/scenarios/manifest_with_deps/modules/dep";

    try std.testing.expect(docent.targeting.isUnderExcludedRoot(dep_file, dep_root));
    try std.testing.expect(docent.targeting.shouldSkipLintFile(dep_file, .{ .exclude_roots = &.{dep_root} }));
}

test "lint_dependencies includes dependency files" {
    const dep_file = "tests/fixtures/scenarios/manifest_with_deps/modules/dep/lib.zig";
    const dep_root = "tests/fixtures/scenarios/manifest_with_deps/modules/dep";

    try std.testing.expect(!docent.targeting.shouldSkipLintFile(dep_file, .{
        .deps = true,
        .exclude_roots = &.{dep_root},
    }));
}

test "explicit exclude_roots" {
    try std.testing.expect(docent.targeting.shouldSkipLintFile("vendor/pkg/util.zig", .{ .exclude_roots = &.{"vendor"} }));
    try std.testing.expect(!docent.targeting.shouldSkipLintFile("src/app.zig", .{ .exclude_roots = &.{"vendor"} }));
}

test "collectDirectoryLintTargets excludes dependency tree by default" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const manifest_path = try fixtureManifestPath(allocator, io);
    defer allocator.free(manifest_path);

    var roots = try docent.manifest.loadDependencyPathRoots(allocator, io, manifest_path);
    defer docent.manifest.deinitOwnedPaths(allocator, &roots);

    const project_root = "tests/fixtures/scenarios/manifest_with_deps";
    var files = try docent.targeting.collectDirectoryLintTargets(allocator, io, project_root, .{ .exclude_roots = roots.items });
    defer docent.targeting.deinitOwnedPaths(allocator, &files);

    var has_app = false;
    var has_dep_lib = false;
    for (files.items) |path| {
        if (std.mem.indexOf(u8, path, "manifest_with_deps") == null) continue;
        const base = std.fs.path.basename(path);
        if (std.mem.eql(u8, base, "app.zig")) has_app = true;
        if (std.mem.eql(u8, base, "lib.zig")) has_dep_lib = true;
    }
    try std.testing.expect(has_app);
    try std.testing.expect(!has_dep_lib);
}

fn fixtureManifestPath(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rel = "tests/fixtures/scenarios/manifest_with_deps/build.zig.zon";
    const len = try std.Io.Dir.cwd().realPathFile(io, rel, &buf);
    return allocator.dupe(u8, buf[0..len]);
}
