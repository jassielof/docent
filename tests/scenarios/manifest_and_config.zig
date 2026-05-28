//! Scenario: build.zig.zon integration, docent.json config, status plan, and build script scan.

const std = @import("std");
const docent = @import("docent");

const manifest_zon = "tests/fixtures/scenarios/manifest_with_deps/build.zig.zon";
const manifest_root = "tests/fixtures/scenarios/manifest_with_deps";

fn fixtureManifestPath(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, manifest_zon, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

fn fixtureConfigPath(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rel = "tests/fixtures/scenarios/manifest_with_deps/.config/docent.json";
    const len = try std.Io.Dir.cwd().realPathFile(io, rel, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

test "manifest dependency path roots from build.zig.zon" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const manifest_path = try fixtureManifestPath(allocator, io);
    defer allocator.free(manifest_path);

    var roots = try docent.manifest.loadDependencyPathRoots(allocator, io, manifest_path);
    defer docent.manifest.deinitOwnedPaths(allocator, &roots);

    try std.testing.expect(roots.items.len == 1);
    try std.testing.expect(std.mem.indexOf(u8, roots.items[0], "modules") != null);
    try std.testing.expect(std.mem.indexOf(u8, roots.items[0], "dep") != null);
}

test "manifest loadPackageMeta reads name and version" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const manifest_path = try fixtureManifestPath(allocator, io);
    defer allocator.free(manifest_path);

    var meta = try docent.manifest.loadPackageMeta(allocator, io, manifest_path);
    defer meta.deinit(allocator);

    try std.testing.expect(meta.name != null);
    try std.testing.expectEqualStrings("fixture", meta.name.?);
    try std.testing.expect(meta.version != null);
    try std.testing.expectEqualStrings("0.0.0", meta.version.?);
    try std.testing.expect(meta.manifest_path != null);
    try std.testing.expect(std.mem.indexOf(u8, meta.project_root, "manifest_with_deps") != null);
}

test "config loadRuleSet reads rules from docent.json" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const config_path = try fixtureConfigPath(allocator, io);
    defer allocator.free(config_path);

    const rule_set = try docent.config.loadRuleSet(allocator, io, config_path);
    try std.testing.expect(rule_set.missing_doc_comment == .deny);
    try std.testing.expect(rule_set.missing_doctest == .allow);
}

test "config explicit config-path loads rules" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const config_path = try fixtureConfigPath(allocator, io);
    defer allocator.free(config_path);

    const rule_set = try docent.config.loadRuleSetFromCli(allocator, io, config_path);
    try std.testing.expect(rule_set.missing_doc_comment == .deny);
    try std.testing.expect(rule_set.missing_doctest == .allow);
}

test "config explicit config-path errors when file is missing" {
    try std.testing.expectError(
        error.ConfigNotFound,
        docent.config.loadRuleSetFromCli(std.testing.allocator, std.testing.io, "tests/fixtures/no_such_docent.json"),
    );
}

test "config empty rules object uses RuleSet defaults" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rel = "tests/fixtures/scenarios/config_defaults/.config/docent.json";
    const len = try std.Io.Dir.cwd().realPathFile(io, rel, &buf);
    const config_path = try allocator.dupe(u8, buf[0..len]);
    defer allocator.free(config_path);

    const rule_set = try docent.config.loadRuleSet(allocator, io, config_path);
    try std.testing.expect(rule_set.missing_doc_comment == .warn);
    try std.testing.expect(rule_set.missing_doctest == .allow);
}

test "build_scan finds dependencies and root sources in build.zig text" {
    const allocator = std.testing.allocator;
    const text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const f = b.dependency("fangz", .{}).module("fangz");
        \\    const m = b.addModule("app", .{ .root_source_file = b.path("src/root.zig"), });
        \\    _ = f;
        \\    _ = m;
        \\}
    ;

    var scan = try docent.build_scan.scanBuildScript(allocator, text);
    defer scan.deinit(allocator);

    try std.testing.expect(scan.dependencies.len == 1);
    try std.testing.expectEqualStrings("fangz", scan.dependencies[0]);
    try std.testing.expect(scan.targets.len == 1);
    try std.testing.expectEqualStrings("src/root.zig", scan.targets[0].root_source_file);
    try std.testing.expectEqualStrings("app", scan.targets[0].name);
    try std.testing.expect(scan.targets[0].kind == .lib);
}

test "status_plan gather manifest fixture has two lint roots and excludes dep" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const manifest_path = try fixtureManifestPath(allocator, io);
    defer allocator.free(manifest_path);

    var dep_roots = try docent.manifest.loadDependencyPathRoots(allocator, io, manifest_path);
    defer docent.manifest.deinitOwnedPaths(allocator, &dep_roots);

    var package_paths = try docent.manifest.loadPackagePaths(allocator, io, manifest_path);
    defer docent.manifest.deinitOwnedPaths(allocator, &package_paths);

    try std.testing.expect(package_paths.items.len == 2);

    var plan = try docent.status_plan.gather(allocator, io, .{ .manifest_path = manifest_path });
    defer plan.deinit(allocator);

    try std.testing.expect(plan.extra_lint_files.len > 0);
    try std.testing.expect(plan.targeting.exclude_roots.len == 1);

    var has_app = false;
    var has_dep_lib = false;
    for (plan.extra_lint_files) |path| {
        const base = std.fs.path.basename(path);
        if (std.mem.eql(u8, base, "app.zig")) has_app = true;
        if (std.mem.eql(u8, base, "lib.zig")) has_dep_lib = true;
    }
    try std.testing.expect(has_app);
    try std.testing.expect(!has_dep_lib);
}
