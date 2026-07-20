//! Guards against [zig#35714](https://codeberg.org/ziglang/zig/issues/35714): the Zig
//! toolchain's `std.zig.Ast.render` takes exponential time to format an array type whose
//! *length* expression is itself an array type, chained arbitrarily deep, e.g.
//! `[[[0]u8]u8]u8`.
//!
//! `renderArrayType` calls `rendersMultiline` on the length expression to decide whether it
//! fits on one line, and `rendersMultiline` fully re-renders that expression into a scratch
//! buffer to check for embedded newlines. When the length expression is itself another array
//! type, that re-render repeats the exact same check on *its* length expression, and so on,
//! roughly doubling the work at every level of nesting. The upstream report measured ~37s to
//! render a chain of depth 24 alone; earlier depths were already multi-second.
//!
//! This is a bug in the installed Zig toolchain's standard library, not in this project, so it
//! cannot be patched from here. Detecting the pathological shape is linear (bounded by
//! `max_depth` per array type encountered), so Docent's formatter runs this check before
//! handing the tree to `std.zig.Ast.render` and refuses to format instead of hanging.
//!
//! Ordinary multi-dimensional arrays (`[N][M][K]T`, nested through the *element* type rather
//! than the length expression) are unaffected by the upstream bug and are not flagged here.

const std = @import("std");
const Ast = std.zig.Ast;

/// Chains deeper than this are refused. Real code has no legitimate reason to nest an array
/// type's length expression inside another array type at all, let alone this deep.
pub const default_max_length_nesting: usize = 16;

/// An array type found at the top of a length-expression chain deeper than the configured limit.
pub const PathologicalArrayType = struct {
    /// The outermost `array_type` / `array_type_sentinel` node starting the chain.
    node: Ast.Node.Index,
    /// Number of array types chained through each other's length expression, capped at
    /// `max_depth + 1` (the exact count past the limit does not matter to callers).
    depth: usize,
};

/// Scans every node in `tree` for an array type whose length expression is itself chained
/// through further array types beyond `max_depth`, returning the first one found (in node
/// order), or `null` when `tree` is safe to hand to `std.zig.Ast.render`.
pub fn findPathologicalArrayType(tree: *const Ast, max_depth: usize) ?PathologicalArrayType {
    const node_count: u32 = @intCast(tree.nodes.len);
    var raw: u32 = 0;
    while (raw < node_count) : (raw += 1) {
        const node: Ast.Node.Index = @enumFromInt(raw);
        if (!isArrayType(tree, node)) continue;

        const depth = lengthNestingDepth(tree, node, max_depth + 1);
        if (depth > max_depth) return .{ .node = node, .depth = depth };
    }
    return null;
}

fn isArrayType(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .array_type, .array_type_sentinel => true,
        else => false,
    };
}

/// Counts how many array types are chained through each other's length expression starting at
/// `node`, stopping early once `limit` is reached — the caller only needs to know whether the
/// chain exceeds its threshold, not its exact length past that point.
fn lengthNestingDepth(tree: *const Ast, node: Ast.Node.Index, limit: usize) usize {
    var depth: usize = 0;
    var current = node;
    while (depth < limit) {
        const array_type = tree.fullArrayType(current) orelse break;
        depth += 1;
        if (!isArrayType(tree, array_type.ast.elem_count)) break;
        current = array_type.ast.elem_count;
    }
    return depth;
}

fn nestedLengthArraySource(allocator: std.mem.Allocator, depth: usize) ![:0]u8 {
    var expr: std.ArrayList(u8) = .empty;
    defer expr.deinit(allocator);
    try expr.appendSlice(allocator, "0");
    for (0..depth) |_| {
        var wrapped: std.ArrayList(u8) = .empty;
        defer wrapped.deinit(allocator);
        try wrapped.append(allocator, '[');
        try wrapped.appendSlice(allocator, expr.items);
        try wrapped.appendSlice(allocator, "]u8");
        expr.clearRetainingCapacity();
        try expr.appendSlice(allocator, wrapped.items);
    }
    return std.fmt.allocPrintSentinel(allocator, "const T = {s};\n", .{expr.items}, 0);
}

test "ordinary declarations are not flagged" {
    const gpa = std.testing.allocator;
    var tree = try std.zig.Ast.parse(gpa, "const a: [3]u8 = undefined;\nconst b: [3][4][5]u8 = undefined;\n", .zig);
    defer tree.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(findPathologicalArrayType(&tree, default_max_length_nesting) == null);
}

test "a chain within the configured limit is not flagged" {
    const gpa = std.testing.allocator;
    const source = try nestedLengthArraySource(gpa, 10);
    defer gpa.free(source);

    var tree = try std.zig.Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(findPathologicalArrayType(&tree, default_max_length_nesting) == null);
}

test "a chain past the configured limit is flagged (zig#35714)" {
    const gpa = std.testing.allocator;
    const source = try nestedLengthArraySource(gpa, 24);
    defer gpa.free(source);

    var tree = try std.zig.Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    const found = findPathologicalArrayType(&tree, default_max_length_nesting) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(found.depth > default_max_length_nesting);
}

test "multi-dimensional arrays nested through the element type are not flagged" {
    const gpa = std.testing.allocator;

    // `[1][2]...[24]u8` chains through `elem_type`, not `elem_count`, so it is unaffected by
    // zig#35714 and must not be treated as pathological.
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    try source.appendSlice(gpa, "const T = ");
    for (1..25) |dim| {
        const segment = try std.fmt.allocPrint(gpa, "[{d}]", .{dim});
        defer gpa.free(segment);
        try source.appendSlice(gpa, segment);
    }
    try source.appendSlice(gpa, "u8;\n");
    const source_z = try gpa.dupeZ(u8, source.items);
    defer gpa.free(source_z);

    var tree = try std.zig.Ast.parse(gpa, source_z, .zig);
    defer tree.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(findPathologicalArrayType(&tree, default_max_length_nesting) == null);
}
