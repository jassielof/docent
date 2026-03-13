const std = @import("std");
const doc_lint = @import("doclint");

fn readFixture(allocator: std.mem.Allocator, rel_path: []const u8) ![:0]const u8 {
    const path = try std.fs.path.join(allocator, &.{ "examples", rel_path });
    defer allocator.free(path);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return try file.readToEndAllocOptions(allocator, std.math.maxInt(u32), null, .of(u8), 0);
}

fn lintFixture(allocator: std.mem.Allocator, rel_path: []const u8, rule_set: doc_lint.RuleSet) !doc_lint.LintResult {
    const source = try readFixture(allocator, rel_path);
    defer allocator.free(source);
    return doc_lint.lintSource(allocator, source, rule_set, rel_path);
}

test "compliant: no missing_doc_comment violations" {
    const allocator = std.testing.allocator;
    var result = try lintFixture(allocator, "compliant/main.zig", .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment")) {
            return error.UnexpectedDiagnostic;
        }
    }
}

test "missing_comments: detects undocumented pub fn and const" {
    const allocator = std.testing.allocator;
    var result = try lintFixture(allocator, "missing_comments/main.zig", .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();

    var count: usize = 0;
    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment")) count += 1;
    }
    try std.testing.expect(count >= 4);
}

test "missing_doctests: detects pub fn without test" {
    const allocator = std.testing.allocator;
    var result = try lintFixture(allocator, "missing_doctests/main.zig", .{
        .missing_doc_comment = .allow,
        .missing_doctest = .warn,
    });
    defer result.deinit();

    var count: usize = 0;
    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doctest")) count += 1;
    }
    try std.testing.expectEqual(1, count);
}

test "mixed: detects multiple rule violations" {
    const allocator = std.testing.allocator;
    var result = try lintFixture(allocator, "mixed/main.zig", .{
        .missing_doc_comment = .warn,
        .empty_doc_comment = .warn,
        .private_doctest = .warn,
        .doctest_naming_mismatch = .warn,
        .missing_container_doc_comment = .warn,
    });
    defer result.deinit();

    var has_missing_doc = false;
    var has_empty_doc = false;
    var has_private_doctest = false;
    var has_naming_mismatch = false;
    var has_missing_container = false;

    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment")) has_missing_doc = true;
        if (std.mem.eql(u8, d.rule, "empty_doc_comment")) has_empty_doc = true;
        if (std.mem.eql(u8, d.rule, "private_doctest")) has_private_doctest = true;
        if (std.mem.eql(u8, d.rule, "doctest_naming_mismatch")) has_naming_mismatch = true;
        if (std.mem.eql(u8, d.rule, "missing_container_doc_comment")) has_missing_container = true;
    }

    try std.testing.expect(has_missing_doc);
    try std.testing.expect(has_empty_doc);
    try std.testing.expect(has_private_doctest);
    try std.testing.expect(has_naming_mismatch);
    try std.testing.expect(has_missing_container);
}

test "compliant: no violations with all rules enabled" {
    const allocator = std.testing.allocator;
    var result = try lintFixture(allocator, "compliant/main.zig", .{
        .missing_doc_comment = .deny,
        .empty_doc_comment = .deny,
        .missing_doctest = .warn,
        .missing_container_doc_comment = .deny,
    });
    defer result.deinit();

    try std.testing.expect(!result.hasErrors());
}

test "severity levels: allow suppresses diagnostics" {
    const allocator = std.testing.allocator;
    var result = try lintFixture(allocator, "mixed/main.zig", .{
        .missing_doc_comment = .allow,
        .empty_doc_comment = .allow,
        .private_doctest = .allow,
        .doctest_naming_mismatch = .allow,
        .missing_container_doc_comment = .allow,
    });
    defer result.deinit();

    try std.testing.expectEqual(0, result.diagnostics.items.len);
}

test "severity levels: deny causes hasErrors" {
    const allocator = std.testing.allocator;
    var result = try lintFixture(allocator, "missing_comments/main.zig", .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    try std.testing.expect(result.errorCount() > 0);
}
