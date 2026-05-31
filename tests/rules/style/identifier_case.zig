//! `identifier_case` — identifiers should follow the Zig naming-case conventions.

const std = @import("std");
const docent = @import("docent");
const utils = @import("../../utils.zig");

// Style checks follow the public API surface; explicit recursive runs check every declaration.
fn lint(source: [:0]const u8, public_api_only: bool) !docent.LintResult {
    return docent.lintStyleSource(
        std.testing.allocator,
        std.testing.io,
        source,
        .{},
        "<test>",
        .{ .public_api_only = public_api_only },
    );
}

test "concrete function should be camelCase" {
    var result = try lint("pub fn DoThing() void {}", true);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
}

test "idiomatic declarations are clean" {
    var result = try lint(
        \\pub const pi = 3.14;
        \\pub const Point = struct {
        \\    x: u32,
        \\    y: u32,
        \\};
        \\pub const Color = enum { red, green };
        \\pub const Error = error{ OutOfMemory };
        \\pub fn parseInt() void {}
        \\pub fn List() type {
        \\    return struct {};
        \\}
    , true);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "field-less container should be snake_case" {
    var result = try lint(
        \\pub const Helpers = struct {
        \\    pub fn ok() void {}
        \\};
    , true);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
}

test "private declarations skipped under public API surface" {
    var result = try lint("fn DoThing() void {}", true);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "private declarations checked in recursive mode" {
    var result = try lint("fn DoThing() void {}", false);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
}

test "snake_case namespace imports in root.zig are not flagged" {
    var result = try docent.lintStyleFile(
        std.testing.allocator,
        std.testing.io,
        "src/lib/root.zig",
        .{},
        .{ .public_api_only = false },
    );
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        if (!std.mem.eql(u8, d.rule, "identifier_case")) continue;
        if (d.subject) |s| {
            if (s.kind == .source_file and std.mem.eql(u8, s.name, "reachability.zig")) {
                return error.UnexpectedDiagnostic;
            }
        }
    }
}

test "warns on PascalCase binding for private namespace import" {
    var result = try docent.lintStyleFile(
        std.testing.allocator,
        std.testing.io,
        "src/lib/rules/docs/blank_doc_comment.zig",
        .{},
        .{ .public_api_only = false },
    );
    defer result.deinit();

    var found_binding = false;
    for (result.diagnostics.items) |d| {
        if (!std.mem.eql(u8, d.rule, "identifier_case")) continue;
        if (d.subject) |s| {
            if (s.kind == .namespace and std.mem.eql(u8, s.name, "Severity")) found_binding = true;
        }
    }
    try std.testing.expect(found_binding);
}

test "function alias re-export does not false positive" {
    var result = try lint(
        \\const helpers = @import("helpers.zig");
        \\pub const parseInt = helpers.parseInt;
    , true);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}
