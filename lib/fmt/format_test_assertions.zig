const std = @import("std");

pub fn expectValidZig(source: []const u8) !void {
    const gpa = std.testing.allocator;
    const source_z = try gpa.dupeZ(u8, source);
    defer gpa.free(source_z);

    var tree = try std.zig.Ast.parse(gpa, source_z, .zig);
    defer tree.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

pub fn expectIdempotent(expected: []const u8, formatted_expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, formatted_expected);
}
