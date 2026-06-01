//! `missing_doc_comment` — public declarations must have doc comments.

const std = @import("std");
const testing = std.testing;
const docent = @import("docent");
const harness = @import("../../harness.zig");
const utils = @import("../../utils.zig");

const ns = "docs";

fn lint(parts: []const []const u8, rule_set: docent.RuleSet) !docent.LintResult {
    return harness.lintRuleFixture(ns, parts, rule_set, .{});
}

fn projectRoot(case_dir: []const u8) ![]const u8 {
    return harness.ruleProjectRootPath(ns, case_dir);
}

test "compliant_pub_declarations has no violations" {
    var result = try lint(&.{"compliant_pub_declarations.zig"}, .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "deny severity causes hasErrors" {
    var result = try lint(&.{"undocumented_pub_declarations.zig"}, .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();
    try testing.expect(result.hasErrors());
    try testing.expect(result.errorCount() > 0);
}

test "undocumented_pub_declarations reports at least four diagnostics" {
    var result = try lint(&.{"undocumented_pub_declarations.zig"}, .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();
    try testing.expect(utils.countRule(result, "missing_doc_comment") >= 4);
}

test "private_struct_members_allowed does not require private field docs" {
    var result = try lint(&.{ "private_struct_members_allowed", "root.zig" }, .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "pub_struct_undocumented_members reports undocumented public members" {
    var result = try lint(&.{ "pub_struct_undocumented_members", "root.zig" }, .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 3);
}

test "reexport_local_binding_documented follows alias to documented symbol" {
    const path = try projectRoot("reexport_local_binding_documented");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{ .missing_doc_comment = .deny }, .{}, &.{}, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "reexport_documented_transitive suppresses diagnostic when definition is documented" {
    const path = try projectRoot("reexport_documented_transitive");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{ .missing_doc_comment = .deny }, .{}, &.{}, .{});
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}

test "reexport_undocumented_points_at_definition uses forward slashes in paths" {
    const path = try projectRoot("reexport_undocumented_points_at_definition");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{ .missing_doc_comment = .deny }, .{}, &.{}, .{});
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment")) {
            try testing.expect(std.mem.indexOf(u8, d.file, "\\") == null);
            try testing.expect(std.mem.endsWith(u8, d.file, "severity.zig"));
        }
    }
}

test "reexport_undocumented_points_at_definition points at definition not re-export line" {
    const path = try projectRoot("reexport_undocumented_points_at_definition");
    defer std.testing.allocator.free(path);

    var result = try docent.lintFile(std.testing.allocator, std.testing.io, path, .{ .missing_doc_comment = .deny }, .{}, &.{}, .{});
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);

    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment")) {
            try testing.expect(!std.mem.endsWith(u8, d.file, "root.zig"));
            try testing.expect(std.mem.endsWith(u8, d.file, "severity.zig"));
        }
    }
}

test "missing_module_doc_on_entry reports missing module doc comment" {
    const allocator = std.testing.allocator;
    const path = try harness.ruleFixturePath(allocator, ns, &.{ "missing_module_doc_on_entry", "root.zig" });
    defer allocator.free(path);
    const source = try harness.readFixtureFile(allocator, std.testing.io, path);
    defer allocator.free(source);
    const display = try harness.relativeFixtureDisplay(allocator, path);
    defer allocator.free(display);

    var result = try docent.lintSource(
        allocator,
        std.testing.io,
        source,
        .{ .missing_doc_comment = .warn },
        display,
        .{ .module_name = "fixture" },
        &.{},
        .{},
    );
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 3);

    var module_doc_count: usize = 0;
    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment") and
            d.subject != null and d.subject.?.kind == .module and
            std.mem.eql(u8, d.subject.?.name, "fixture"))
        {
            module_doc_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), module_doc_count);
}

test "lintSource honors require_function_param_docs option" {
    const source: [:0]const u8 =
        \\/// Does something.
        \\pub fn foo(allocator: std.mem.Allocator) void {
        \\    _ = allocator;
        \\}
    ;
    var result = try docent.lintSource(
        std.testing.allocator,
        std.testing.io,
        source,
        .{ .missing_doc_comment = .deny },
        "<test>",
        .{},
        &.{},
        .{ .require_function_param_docs = true },
    );
    defer result.deinit();
    try utils.expectRuleCount(result, "missing_doc_comment", 1);
    try testing.expectEqual(.parameter, result.diagnostics.items[0].subject.?.kind);
    try testing.expectEqualStrings("allocator", result.diagnostics.items[0].subject.?.name);
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
        .{},
    );
    defer result.deinit();
    try utils.expectRuleAbsent(result, "missing_doc_comment");
}
