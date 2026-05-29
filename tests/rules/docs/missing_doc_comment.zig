//! `missing_doc_comment` — public declarations must have doc comments.

const std = @import("std");
const testing = std.testing;
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const loc: harness.RuleLocator = .{ .namespace = "docs", .rule_id = "missing_doc_comment" };

fn lint(parts: []const []const u8, rule_set: docent.RuleSet) !docent.LintResult {
    return harness.lintRuleFixture(loc, parts, rule_set);
}

fn projectRoot(kind: []const u8, case_name: []const u8) ![]const u8 {
    return harness.ruleProjectRootPath(loc, kind, case_name);
}

test "valid compliant fixture has no violations" {
    var result = try lint(&.{ "valid", "compliant", "main.zig" }, .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "deny severity causes hasErrors" {
    var result = try lint(&.{ "invalid", "missing_comments", "main.zig" }, .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();
    try testing.expect(result.hasErrors());
    try testing.expect(result.errorCount() > 0);
}

// Undocumented `pub fn` and `pub const` in a single file.
test "invalid missing_comments reports at least four diagnostics" {
    var result = try lint(&.{ "invalid", "missing_comments", "main.zig" }, .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();
    try testing.expect(utils.countRule(result, "missing_doc_comment") >= 4);
}

test "valid private struct members are not required to document private fields" {
    var result = try lint(&.{ "valid", "private_struct_private_members", "root.zig" }, .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "invalid public struct reports undocumented public members" {
    var result = try lint(&.{ "invalid", "public_struct_undocumented_members", "root.zig" }, .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 3);
}

test "project reexport_local_binding follows alias to documented symbol" {
    const path = try projectRoot("valid", "reexport_local_binding");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{ .missing_doc_comment = .deny }, .{}, &.{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "project reexport_documented suppresses diagnostic when definition is documented" {
    const path = try projectRoot("valid", "reexport_documented");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{ .missing_doc_comment = .deny }, .{}, &.{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "project reexport_undocumented uses forward slashes in paths" {
    const path = try projectRoot("invalid", "reexport_undocumented");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{ .missing_doc_comment = .deny }, .{}, &.{});
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment")) {
            try std.testing.expect(std.mem.indexOf(u8, d.file, "\\") == null);
            try std.testing.expect(std.mem.endsWith(u8, d.file, "severity.zig"));
        }
    }
}

test "project reexport_undocumented points at definition not re-export line" {
    const path = try projectRoot("invalid", "reexport_undocumented");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{ .missing_doc_comment = .deny }, .{}, &.{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);

    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment")) {
            try std.testing.expect(!std.mem.endsWith(u8, d.file, "root.zig"));
            try std.testing.expect(std.mem.endsWith(u8, d.file, "severity.zig"));
        }
    }
}

test "invalid missing_module_doc reports missing module doc comment on root.zig" {
    var result = try lint(&.{ "invalid", "missing_module_doc", "root.zig" }, .{
        .missing_doc_comment = .warn,
    });
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 3);

    var module_doc_count: usize = 0;
    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment") and
            std.mem.indexOf(u8, d.message, "missing module doc comment") != null)
        {
            module_doc_count += 1;
            try std.testing.expect(std.mem.indexOf(u8, d.message, "root.zig") != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), module_doc_count);
}

test "unresolvable import produces no false positive in single-file mode" {
    const source: [:0]const u8 =
        "//! Module.\npub const Foo = @import(\"definitely_nonexistent_xyz.zig\").Bar;";
    var result = try docent.lintSource(
        std.testing.allocator,
        std.testing.io,
        source,
        .{ .missing_doc_comment = .deny },
        "<fake-file.zig>",
        .{},
        &.{},
    );
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}
