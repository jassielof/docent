//! Scenario: public API reachability and multi-file lint coverage.

const std = @import("std");
const docent = @import("docent");
const harness = @import("../harness.zig");
const utils = @import("../utils.zig");

const loc: harness.ScenarioLocator = .{ .name = "reachability" };

test "collects only public reachable files from public_api root" {
    const root = try harness.scenarioProjectPath(loc, "public_api/root.zig");
    defer std.testing.allocator.free(root);

    var files = try docent.reachability.collectReachablePublicFiles(std.testing.allocator, std.testing.io, root);
    defer docent.reachability.deinitOwnedPaths(std.testing.allocator, &files);

    var has_root = false;
    var has_vision = false;
    var has_utils = false;

    for (files.items) |path| {
        if (std.mem.indexOf(u8, path, "public_api") == null) continue;
        const base = std.fs.path.basename(path);
        if (std.mem.eql(u8, base, "root.zig")) has_root = true;
        if (std.mem.eql(u8, base, "Vision.zig")) has_vision = true;
        if (std.mem.eql(u8, base, "utils.zig")) has_utils = true;
    }

    try std.testing.expect(has_root);
    try std.testing.expect(has_vision);
    try std.testing.expect(!has_utils);
}

test "linting reachable public_api files emits no missing_doc_comment" {
    const root = try harness.scenarioProjectPath(loc, "public_api/root.zig");
    defer std.testing.allocator.free(root);

    var files = try docent.reachability.collectReachablePublicFiles(std.testing.allocator, std.testing.io, root);
    defer docent.reachability.deinitOwnedPaths(std.testing.allocator, &files);

    for (files.items) |path| {
        var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{ .missing_doc_comment = .warn }, .{}, &.{});
        defer result.deinit();
        try utils.expectRuleAbsent(result, "missing_doc_comment");
    }
}

test "recursively follows multi-hop public imports in public_api_deep" {
    const root = try harness.scenarioProjectPath(loc, "public_api_deep/root.zig");
    defer std.testing.allocator.free(root);

    var files = try docent.reachability.collectReachablePublicFiles(std.testing.allocator, std.testing.io, root);
    defer docent.reachability.deinitOwnedPaths(std.testing.allocator, &files);

    var has_root = false;
    var has_api = false;
    var has_model = false;
    var has_extra = false;
    var has_private_only = false;

    for (files.items) |path| {
        if (std.mem.indexOf(u8, path, "public_api_deep") == null) continue;
        const base = std.fs.path.basename(path);
        if (std.mem.eql(u8, base, "root.zig")) has_root = true;
        if (std.mem.eql(u8, base, "api.zig")) has_api = true;
        if (std.mem.eql(u8, base, "model.zig")) has_model = true;
        if (std.mem.eql(u8, base, "extra.zig")) has_extra = true;
        if (std.mem.eql(u8, base, "private_only.zig")) has_private_only = true;
    }

    try std.testing.expect(has_root and has_api and has_model and has_extra);
    try std.testing.expect(!has_private_only);
}

test "private-only file is excluded from linted deep set" {
    const root = try harness.scenarioProjectPath(loc, "public_api_deep/root.zig");
    defer std.testing.allocator.free(root);

    var files = try docent.reachability.collectReachablePublicFiles(std.testing.allocator, std.testing.io, root);
    defer docent.reachability.deinitOwnedPaths(std.testing.allocator, &files);

    for (files.items) |path| {
        var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{ .missing_doc_comment = .warn }, .{}, &.{});
        defer result.deinit();
        try utils.expectRuleAbsent(result, "missing_doc_comment");
    }
}
