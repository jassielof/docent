//! `identifier_case` — identifiers should follow the Zig naming-case conventions.

const std = @import("std");
const docent = @import("docent");
const utils = @import("../../utils.zig");

fn lint(source: [:0]const u8, scan_mode: docent.scan_modes.Mode) !docent.LintResult {
    var style_options = docent.rules.style.Options.defaults();
    style_options.applyRunScanMode(scan_mode);
    return docent.lintStyleSource(
        std.testing.allocator,
        std.testing.io,
        source,
        .{},
        "<test>",
        style_options,
    );
}

test "concrete function should be camelCase" {
    var result = try lint("pub fn DoThing() void {}", .public_api_surface);
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
    , .public_api_surface);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "field-less container should be snake_case" {
    var result = try lint(
        \\pub const Helpers = struct {
        \\    pub fn ok() void {}
        \\};
    , .public_api_surface);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
}

test "private declarations skipped under public API surface" {
    var result = try lint("fn DoThing() void {}", .public_api_surface);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}

test "private declarations checked in recursive mode" {
    var result = try lint("fn DoThing() void {}", .reachability_traversal);
    defer result.deinit();
    try utils.expectRuleCount(result, "identifier_case", 1);
}

test "snake_case namespace imports in root.zig are not flagged" {
    var style_options = docent.rules.style.Options.defaults();
    style_options.applyRunScanMode(.reachability_traversal);
    var result = try docent.lintStyleFile(
        std.testing.allocator,
        std.testing.io,
        "src/lib/root.zig",
        .{},
        style_options,
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

test "import member re-export in root.zig is not flagged" {
    var style_options = docent.rules.style.Options.defaults();
    style_options.applyRunScanMode(.reachability_traversal);
    var result = try docent.lintStyleFile(
        std.testing.allocator,
        std.testing.io,
        "src/lib/root.zig",
        .{},
        style_options,
    );
    defer result.deinit();

    for (result.diagnostics.items) |d| {
        if (!std.mem.eql(u8, d.rule, "identifier_case")) continue;
        if (d.subject) |s| {
            if (std.mem.eql(u8, s.name, "SeverityLevel")) return error.UnexpectedDiagnostic;
        }
    }
}

test "function alias re-export does not false positive" {
    var result = try lint(
        \\const helpers = @import("helpers.zig");
        \\pub const parseInt = helpers.parseInt;
    , .public_api_surface);
    defer result.deinit();
    try utils.expectRuleAbsent(result, "identifier_case");
}
