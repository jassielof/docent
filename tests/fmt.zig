const std = @import("std");
const docent = @import("docent");
const Fmt = docent.Fmt;

test "allman brace style" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/allman.zig");
    const expected = @embedFile("fixtures/fmt/expected/allman.zig");
    const result = try Fmt.convertToAllman(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "brace_style.convert dispatches by style" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/allman.zig");

    const k_r_result = try Fmt.brace_style.convert(gpa, input, .k_r);
    defer gpa.free(k_r_result);
    try std.testing.expectEqualStrings(input, k_r_result);

    const allman_result = try Fmt.brace_style.convert(gpa, input, .allman);
    defer gpa.free(allman_result);
    const expected_allman = try Fmt.convertToAllman(gpa, input);
    defer gpa.free(expected_allman);
    try std.testing.expectEqualStrings(expected_allman, allman_result);
}

test "single line braces" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/single_line_braces.zig");
    const expected = @embedFile("fixtures/fmt/expected/single_line_braces.zig");
    const result = try Fmt.enforceBraces(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "trailing comma" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/trailing_comma.zig");
    const expected = @embedFile("fixtures/fmt/expected/trailing_comma.zig");
    const result = try Fmt.addTrailingCommas(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "sort imports" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/sort_imports.zig");
    const expected = @embedFile("fixtures/fmt/expected/sort_imports.zig");
    const result = try Fmt.sortImports(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "logical blank lines" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/logical_blank_lines.zig");
    const expected = @embedFile("fixtures/fmt/expected/logical_blank_lines.zig");
    const result = try Fmt.enforceLogicalBlankLines(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "indent width 2" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/indent_width.zig");
    const expected = @embedFile("fixtures/fmt/expected/indent_width_2.zig");
    const result = try Fmt.reindent(gpa, input, .space, 2);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "indent style tabs" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/indent_width.zig");
    const expected = @embedFile("fixtures/fmt/expected/indent_width_tabs.zig");
    const result = try Fmt.reindent(gpa, input, .tab, 4);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}
