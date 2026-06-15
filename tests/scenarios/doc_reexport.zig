//! Re-export project scenarios for doc rules.

const std = @import("std");
const testing = std.testing;
const docent = @import("docent");
const harness = @import("../harness.zig");
const utils = @import("../utils.zig");

test "reexport_local_binding_documented follows alias to documented symbol" {
    const path = try harness.scenarioProjectRootPath("reexport_local_binding_documented");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{}, &.{}, harness.docConfig(.{ .missing_doc_comment = .deny }));
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "reexport_documented_transitive suppresses diagnostic when definition is documented" {
    const path = try harness.scenarioProjectRootPath("reexport_documented_transitive");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{}, &.{}, harness.docConfig(.{ .missing_doc_comment = .deny }));
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "reexport_undocumented_points_at_definition uses forward slashes in paths" {
    const path = try harness.scenarioProjectRootPath("reexport_undocumented_points_at_definition");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{}, &.{}, harness.docConfig(.{ .missing_doc_comment = .deny }));
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment")) {
            try testing.expect(std.mem.indexOf(u8, d.file, "\\") == null);
            try testing.expect(std.mem.endsWith(u8, d.file, "severity.zig"));
        }
    }
}

test "reexport_undocumented_points_at_definition points at definition not re-export line" {
    const path = try harness.scenarioProjectRootPath("reexport_undocumented_points_at_definition");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{}, &.{}, harness.docConfig(.{ .missing_doc_comment = .deny }));
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);

    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment")) {
            try testing.expect(!std.mem.endsWith(u8, d.file, "root.zig"));
            try testing.expect(std.mem.endsWith(u8, d.file, "severity.zig"));
        }
    }
}

test "whole-module re-export reports missing namespace doc on imported file" {
    const path = try harness.scenarioProjectRootPath("reexport_missing_whole_namespace");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{}, &.{}, harness.docConfig(.{ .missing_doc_comment = .deny }));
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);
    try testing.expectEqual(.namespace, result.diagnostics.items[0].subject.?.kind);
    try testing.expect(std.mem.endsWith(u8, result.diagnostics.items[0].file, "enums.zig"));
}

test "whole-module re-export resolves blank namespace doc on imported file" {
    const path = try harness.scenarioProjectRootPath("reexport_blank_whole_namespace");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{}, &.{}, harness.docConfig(.{ .blank_doc_comment = .warn }));
    defer result.deinit();
    try utils.expectRuleCount(result, "blank_doc_comment", 1);
    try testing.expectEqual(.namespace, result.diagnostics.items[0].subject.?.kind);
    try testing.expect(std.mem.endsWith(u8, result.diagnostics.items[0].file, "enums.zig"));
}

test "member-only re-export does not require module doc on imported file" {
    const path = try harness.scenarioProjectRootPath("reexport_member_only_no_module_doc");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{}, &.{}, harness.docConfig(.{
        .missing_doc_comment = .deny,
        .blank_doc_comment = .warn,
    }));
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
    try utils.expectRuleAbsent(result, "blank_doc_comment");
}
