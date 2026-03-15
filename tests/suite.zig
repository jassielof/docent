const std = @import("std");
const doc_lint = @import("doclint");

fn readFixture(allocator: std.mem.Allocator, rel_path: []const u8) ![:0]const u8 {
    const path = try std.fs.path.join(allocator, &.{ "tests", "fixtures", rel_path });
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
    var result = try lintFixture(allocator, "valid/compliant/main.zig", .{
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
    var result = try lintFixture(allocator, "invalid/missing_comments/main.zig", .{
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
    var result = try lintFixture(allocator, "invalid/missing_doctests/main.zig", .{
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
    var result = try lintFixture(allocator, "invalid/mixed/main.zig", .{
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
    var result = try lintFixture(allocator, "valid/compliant/main.zig", .{
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
    var result = try lintFixture(allocator, "invalid/mixed/main.zig", .{
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
    var result = try lintFixture(allocator, "invalid/missing_comments/main.zig", .{
        .missing_doc_comment = .deny,
    });
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    try std.testing.expect(result.errorCount() > 0);
}

// ── Re-export resolution tests ─────────────────────────────────────────────

test "reexport_documented: no diagnostic when original declaration is documented" {
    // `root.zig` has `pub const Severity = @import("severity.zig").Level` with no
    // doc comment on the re-export line, but `Level` in `severity.zig` IS documented.
    // The linter must follow the import and suppress the diagnostic.
    //
    // Use lintFile with the full path so dirname() resolves correctly from CWD.
    var result = try doc_lint.lintFile(
        std.testing.allocator,
        "tests/fixtures/valid/reexport_documented/root.zig",
        .{ .missing_doc_comment = .deny },
    );
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment")) {
            std.debug.print("Unexpected diagnostic: {s}:{d}:{d}: {s}\n", .{ d.file, d.line, d.column, d.message });
            return error.UnexpectedDiagnostic;
        }
    }
}

test "reexport_undocumented: diagnostic points to definition site, not re-export" {
    // `root.zig` re-exports `Level` from `severity.zig`, but `Level` has no doc
    // comment.  Exactly one `missing_doc_comment` diagnostic must be emitted and
    // it must point into `severity.zig`, NOT into `root.zig`.
    var result = try doc_lint.lintFile(
        std.testing.allocator,
        "tests/fixtures/invalid/reexport_undocumented/root.zig",
        .{ .missing_doc_comment = .deny },
    );
    defer result.deinit();

    var count: usize = 0;
    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment")) {
            count += 1;
            // Diagnostic must NOT point at the re-export line in root.zig.
            try std.testing.expect(!std.mem.endsWith(u8, d.file, "root.zig"));
            // Diagnostic MUST point at the original definition in severity.zig.
            try std.testing.expect(std.mem.endsWith(u8, d.file, "severity.zig"));
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "reexport: unresolvable import produces no false positive (single-file mode)" {
    // When lintSource is given a fake file path and the imported file does not
    // exist on disk, the re-export must be silently skipped — no false positive.
    // String literals in Zig are null-terminated, so they coerce to [:0]const u8.
    const source: [:0]const u8 =
        "//! Module.\npub const Foo = @import(\"definitely_nonexistent_xyz.zig\").Bar;";
    var result = try doc_lint.lintSource(
        std.testing.allocator,
        source,
        .{ .missing_doc_comment = .deny },
        "<fake-file.zig>",
    );
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.rule, "missing_doc_comment")) {
            return error.UnexpectedDiagnostic;
        }
    }
}
