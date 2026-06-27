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
    const result = try Fmt.reindent(gpa, input, 2);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}
