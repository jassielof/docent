const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

pub const types = @import("sort_imports/types.zig");
pub const extractor = @import("sort_imports/extractor.zig");
pub const classifier = @import("sort_imports/classifier.zig");
pub const sorter = @import("sort_imports/sorter.zig");
pub const renderer = @import("sort_imports/renderer.zig");

/// Sorts the leading top-level import block using AST-based extraction.
///
/// Imports are regrouped into categories (builtin, std, dependencies, root,
/// local files, conditionals) separated by blank lines. Within each category,
/// imports are sorted case-insensitively by const identifier. Aliases are
/// placed directly beneath the import they derive from.
///
/// Internal and public imports are separated by a double blank line.
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
