const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const format_test_assertions = @import("format_test_assertions.zig");
pub const classifier = @import("sort_imports/classifier.zig");
pub const extractor = @import("sort_imports/extractor.zig");
pub const renderer = @import("sort_imports/renderer.zig");
pub const sorter = @import("sort_imports/sorter.zig");
pub const types = @import("sort_imports/types.zig");

test "sorts imports" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/sort_imports/input.zig");
    const expected = @embedFile("fixtures/sort_imports/expected.zig");

    const formatted = try sortImports(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try sortImports(gpa, expected);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "keeps conditional imports in their origin category and orders reexports by base path" {
    const gpa = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\const zoo = @import("zoo.zig");
        \\const alpha = @import("alpha.zig");
        \\const platform = if (std.builtin.os.tag == .windows)
        \\    @import("platform/windows.zig")
        \\else
        \\    @import("platform/posix.zig");
        \\const dependency = if (std.builtin.os.tag == .windows)
        \\    @import("windows-dependency")
        \\else
        \\    @import("posix-dependency");
        \\pub const Aardvark = zoo.Value;
        \\pub const Zebra = alpha.Value;
        \\
    ;
    const expected =
        \\const std = @import("std");
        \\
        \\const dependency = if (std.builtin.os.tag == .windows)
        \\    @import("windows-dependency")
        \\else
        \\    @import("posix-dependency");
        \\
        \\const alpha = @import("alpha.zig");
        \\const zoo = @import("zoo.zig");
        \\const platform = if (std.builtin.os.tag == .windows)
        \\    @import("platform/windows.zig")
        \\else
        \\    @import("platform/posix.zig");
        \\
        \\pub const Zebra = alpha.Value;
        \\pub const Aardvark = zoo.Value;
        \\
    ;

    const formatted = try sortImports(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

/// Sorts the leading top-level import block using AST-based extraction.
///
/// Imports are regrouped into categories (std, builtin, root, dependencies,
/// local files) separated by blank lines. Bases sort by import path and
/// aliases remain directly beneath their base, ordered by accessed member path.
/// Conditional imports join the origin category of their most-local branch and
/// remain at the end of that category.
///
/// Internal and public imports are separated by a single blank line (Zig's
/// formatter collapses consecutive blank lines, so a double gap would not
/// survive a subsequent `zig fmt` / AST render pass).
/// Only the contiguous leading import block is touched.
pub fn sortImports(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sentinel_input = try gpa.dupeZ(u8, input);
    defer gpa.free(sentinel_input);

    var tree = std.zig.Ast.parse(gpa, sentinel_input, .zig) catch return gpa.dupe(u8, input);
    defer tree.deinit(gpa);

    if (tree.errors.len != 0) return gpa.dupe(u8, input);

    const result = extractor.extract(arena, &tree) catch return gpa.dupe(u8, input);
    if (result.entries.len == 0) return gpa.dupe(u8, input);

    const groups = sorter.buildGroups(arena, result.entries) catch return gpa.dupe(u8, input);
    const rendered = renderer.render(arena, groups, result.entries) catch return gpa.dupe(u8, input);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    const prefix = input[0..result.block_start];
    try output.ensureTotalCapacity(gpa, prefix.len + rendered.len + (input.len - result.block_end) + 2);

    try output.appendSlice(gpa, prefix);

    if (rendered.len > 0 and rendered[rendered.len - 1] != '\n') {
        try output.appendSlice(gpa, rendered);
        try output.append(gpa, '\n');
    } else {
        try output.appendSlice(gpa, rendered);
    }

    if (result.block_end < input.len) {
        var rest_start = result.block_end;
        while (rest_start < input.len and (input[rest_start] == '\n' or input[rest_start] == '\r')) rest_start += 1;
        if (rest_start < input.len) {
            try output.appendSlice(gpa, input[rest_start..]);
        }
    }

    return output.toOwnedSlice(gpa);
}
