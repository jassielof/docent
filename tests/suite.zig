const std = @import("std");
const docent = @import("docent");

fn readFixture(allocator: std.mem.Allocator, rel_path: []const u8) ![:0]const u8 {
    const path = try std.fs.path.join(allocator, &.{ "tests", "fixtures", rel_path });
    defer allocator.free(path);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return try file.readToEndAllocOptions(allocator, std.math.maxInt(u32), null, .of(u8), 0);
}

fn lintFixture(allocator: std.mem.Allocator, rel_path: []const u8, rule_set: docent.RuleSet) !docent.LintResult {
    const source = try readFixture(allocator, rel_path);
    defer allocator.free(source);
    return docent.lintSource(allocator, source, rule_set, rel_path);
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
    var result = try docent.lintFile(
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
    var result = try docent.lintFile(
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
    var result = try docent.lintSource(
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

// ── Reachability tests ────────────────────────────────────────────────────

test "reachability: collects only public reachable files from root.zig" {
    var files = try docent.reachability.collectReachablePublicFiles(
        std.testing.allocator,
        "tests/fixtures/valid/public_api/root.zig",
    );
    defer docent.reachability.deinitOwnedPaths(std.testing.allocator, &files);

    var has_root = false;
    var has_vision = false;
    var has_utils = false;

    for (files.items) |path| {
        if (std.mem.indexOf(u8, path, "public_api") == null) continue;

        const base = std.fs.path.basename(path);
        if (std.mem.eql(u8, base, "root.zig")) has_root = true;
        if (std.mem.eql(u8, base, "vision.zig")) has_vision = true;
        if (std.mem.eql(u8, base, "utils.zig")) has_utils = true;
    }

    try std.testing.expect(has_root);
    try std.testing.expect(has_vision);
    try std.testing.expect(!has_utils);
}

test "reachability: linting reachable public_api emits no missing_doc_comment" {
    var files = try docent.reachability.collectReachablePublicFiles(
        std.testing.allocator,
        "tests/fixtures/valid/public_api/root.zig",
    );
    defer docent.reachability.deinitOwnedPaths(std.testing.allocator, &files);

    for (files.items) |path| {
        var result = try docent.lintFile(
            std.testing.allocator,
            path,
            .{ .missing_doc_comment = .warn },
        );
        defer result.deinit();

        for (result.diagnostics.items) |d| {
            if (std.mem.eql(u8, d.rule, "missing_doc_comment")) {
                std.debug.print("Unexpected diagnostic in reachable file: {s}:{d}:{d}: {s}\n", .{ d.file, d.line, d.column, d.message });
                return error.UnexpectedDiagnostic;
            }
        }
    }
}

test "reachability: recursively follows multi-hop public imports" {
    var files = try docent.reachability.collectReachablePublicFiles(
        std.testing.allocator,
        "tests/fixtures/valid/public_api_deep/root.zig",
    );
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

    try std.testing.expect(has_root);
    try std.testing.expect(has_api);
    try std.testing.expect(has_model);
    try std.testing.expect(has_extra);
    try std.testing.expect(!has_private_only);
}

test "reachability: private-only file is excluded from linted deep set" {
    var files = try docent.reachability.collectReachablePublicFiles(
        std.testing.allocator,
        "tests/fixtures/valid/public_api_deep/root.zig",
    );
    defer docent.reachability.deinitOwnedPaths(std.testing.allocator, &files);

    for (files.items) |path| {
        var result = try docent.lintFile(
            std.testing.allocator,
            path,
            .{ .missing_doc_comment = .warn },
        );
        defer result.deinit();

        for (result.diagnostics.items) |d| {
            if (std.mem.eql(u8, d.rule, "missing_doc_comment")) {
                std.debug.print("Unexpected diagnostic in reachable deep file: {s}:{d}:{d}: {s}\n", .{ d.file, d.line, d.column, d.message });
                return error.UnexpectedDiagnostic;
            }
        }
    }
}
