const std = @import("std");
const testing = std.testing;
const allocator = std.testing.allocator;

const docent = @import("docent");

const Fmt = docent.Fmt;

const FIXTURES = "fixtures/fmt";

/// Confirms a formatting pass's output is still syntactically valid Zig
/// (zero AST errors) -- guards against a post-processing transform
/// (brace_style, indent_width, trailing_comma, etc.) corrupting otherwise
/// well-formed source.
fn expectValidZig(source: []const u8) !void {
    const gpa = allocator;
    const source_z = try gpa.dupeZ(u8, source);
    defer gpa.free(source_z);

    var tree = try std.zig.Ast.parse(gpa, source_z, .zig);
    defer tree.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "allman brace style" {
    const gpa = allocator;
    const input = @embedFile(FIXTURES ++ "/input/allman.zig");
    const expected = @embedFile(FIXTURES ++ "/expected/allman.zig");
    const result = try Fmt.convertToAllman(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
    try expectValidZig(result);
}

test "brace_style.convert dispatches by style" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/allman.zig");

    const k_r_result = try Fmt.brace_style.convert(gpa, input, .k_r);
    defer gpa.free(k_r_result);
    try std.testing.expectEqualStrings(input, k_r_result);
    try expectValidZig(k_r_result);

    const allman_result = try Fmt.brace_style.convert(gpa, input, .allman);
    defer gpa.free(allman_result);
    const expected_allman = try Fmt.convertToAllman(gpa, input);
    defer gpa.free(expected_allman);
    try std.testing.expectEqualStrings(expected_allman, allman_result);
    try expectValidZig(allman_result);
}

test "single line braces" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/single_line_braces.zig");
    const expected = @embedFile("fixtures/fmt/expected/single_line_braces.zig");
    const result = try Fmt.enforceBraces(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
    try expectValidZig(result);
}

test "trailing comma" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/trailing_comma.zig");
    const expected = @embedFile("fixtures/fmt/expected/trailing_comma.zig");
    const result = try Fmt.addTrailingCommas(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
    try expectValidZig(result);
}

test "sort imports" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/sort_imports.zig");
    const expected = @embedFile("fixtures/fmt/expected/sort_imports.zig");
    const result = try Fmt.sortImports(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
    try expectValidZig(result);
}

test "logical blank lines" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/logical_blank_lines.zig");
    const expected = @embedFile("fixtures/fmt/expected/logical_blank_lines.zig");
    const result = try Fmt.enforceLogicalBlankLines(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
    try expectValidZig(result);
}

test "indent width 2" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/indent_width.zig");
    const expected = @embedFile("fixtures/fmt/expected/indent_width_2.zig");
    const result = try Fmt.reindent(gpa, input, .space, 2);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
    try expectValidZig(result);
}

test "indent style tabs" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/indent_width.zig");
    const expected = @embedFile("fixtures/fmt/expected/indent_width_tabs.zig");
    const result = try Fmt.reindent(gpa, input, .tab, 4);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
    try expectValidZig(result);
}
