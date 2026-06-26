const std = @import("std");
const docent = @import("docent");
const convertToAllman = docent.Fmt.convertToAllman;

test "allman brace style" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/fmt/input/allman.zig");
    const expected = @embedFile("fixtures/fmt/expected/allman.zig");
    const result = try convertToAllman(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}
