//! Shared helper for complexity rules (`cognitive`, `cyclomatic`) to turn
//! their per-node score increments into `Diagnostic.Span`s for pretty-mode
//! rendering, without duplicating the "keep the top contributors, then
//! reorder them to read top-to-bottom, then dupe their source lines" logic
//! in each rule.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const Diagnostic = @import("Diagnostic.zig");

/// One node's contribution to a complexity score, before rendering.
pub const Increment = struct {
    token: Ast.TokenIndex,
    points: u32,
    reason: []const u8,
};

/// Builds up to `max_spans` `Diagnostic.Span`s from `increments`: the
/// highest-scoring ones are kept (ties broken by source order), then
/// re-ordered to ascending source position so the rendered block reads
/// top-to-bottom like the function body itself. Caller owns the returned
/// slice — including each span's `source_line`/`label` — via `allocator`.
pub fn buildSpans(
    allocator: Allocator,
    tree: *const Ast,
    increments: []const Increment,
    max_spans: usize,
) Allocator.Error![]Diagnostic.Span {
    if (increments.len == 0 or max_spans == 0) return &.{};

    const scratch = try allocator.dupe(Increment, increments);
    defer allocator.free(scratch);

    // Ties are common for cyclomatic complexity (every decision point is
    // worth exactly 1) — break them by source position so selection is
    // deterministic instead of depending on sort implementation details.
    std.mem.sort(Increment, scratch, tree, byPointsDescendingThenPosition);
    const kept = scratch[0..@min(max_spans, scratch.len)];
    std.mem.sort(Increment, kept, tree, bySourcePosition);

    var spans: std.ArrayList(Diagnostic.Span) = .empty;
    errdefer {
        for (spans.items) |span| {
            allocator.free(span.source_line);
            allocator.free(span.label);
        }
        spans.deinit(allocator);
    }

    for (kept) |increment| {
        const loc = tree.tokenLocation(0, increment.token);
        try spans.append(allocator, .{
            .line = loc.line + 1,
            .column = loc.column + 1,
            .symbol_len = tree.tokenSlice(increment.token).len,
            .source_line = try dupSourceLine(tree, increment.token, allocator),
            .label = try std.fmt.allocPrint(
                allocator,
                "+{d} ({s})",
                .{ increment.points, increment.reason },
            ),
        });
    }

    return spans.toOwnedSlice(allocator);
}

/// Returns the 1-based source line of the highest-scoring increment (ties
/// broken by earliest source position), or `null` if `increments` is empty.
/// Meant for a generic "start looking here" pointer in a `= help:` note.
pub fn topLine(tree: *const Ast, increments: []const Increment) ?usize {
    if (increments.len == 0) return null;

    var best = increments[0];
    for (increments[1..]) |candidate| {
        if (byPointsDescendingThenPosition(tree, candidate, best)) best = candidate;
    }
    return tree.tokenLocation(0, best.token).line + 1;
}

fn byPointsDescendingThenPosition(tree: *const Ast, a: Increment, b: Increment) bool {
    if (a.points != b.points) return a.points > b.points;
    return tree.tokenStart(a.token) < tree.tokenStart(b.token);
}

fn bySourcePosition(tree: *const Ast, a: Increment, b: Increment) bool {
    return tree.tokenStart(a.token) < tree.tokenStart(b.token);
}

fn dupSourceLine(tree: *const Ast, token: Ast.TokenIndex, allocator: Allocator) ![]const u8 {
    const loc = tree.tokenLocation(0, token);
    var end = loc.line_start;
    while (end < tree.source.len and tree.source[end] != '\n') end += 1;
    return allocator.dupe(u8, std.mem.trimEnd(
        u8,
        tree.source[loc.line_start..end],
        "\r",
    ));
}

test "keeps the highest-scoring increments and orders them by source position" {
    const gpa = std.testing.allocator;
    const source =
        \\fn f() void {
        \\    var x: u32 = 0;
        \\    x += 1;
        \\    x += 2;
        \\    x += 3;
        \\}
        \\
    ;
    var tree = try Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);

    // Fabricate increments anchored at the four statement-starting tokens
    // (var/x/x/x), out of score order and out of source order, to verify
    // both the top-N selection and the final source-order re-sort.
    var toks: [4]Ast.TokenIndex = undefined;
    var count: usize = 0;
    for (0..tree.tokens.len) |i| {
        const tag = tree.tokenTag(@intCast(i));
        if (tag == .keyword_var or (tag == .identifier and std.mem.eql(u8, tree.tokenSlice(@intCast(i)), "x"))) {
            if (count < toks.len) {
                toks[count] = @intCast(i);
                count += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 4), count);

    const increments = [_]Increment{
        .{ .token = toks[3], .points = 1, .reason = "third" },
        .{ .token = toks[0], .points = 5, .reason = "first" },
        .{ .token = toks[1], .points = 3, .reason = "second" },
        .{ .token = toks[2], .points = 4, .reason = "fourth" },
    };

    const spans = try buildSpans(gpa, &tree, &increments, 3);
    defer {
        for (spans) |span| {
            gpa.free(span.source_line);
            gpa.free(span.label);
        }
        gpa.free(spans);
    }

    // Top 3 by points: first(5), fourth(4), second(3) — then re-ordered to
    // source position: first, second, fourth.
    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqualStrings("+5 (first)", spans[0].label);
    try std.testing.expectEqualStrings("+3 (second)", spans[1].label);
    try std.testing.expectEqualStrings("+4 (fourth)", spans[2].label);

    // `first` (5 points, at line 2) is the single highest scorer.
    try std.testing.expectEqual(@as(?usize, 2), topLine(&tree, &increments));
}

test "topLine breaks ties by earliest source position" {
    const gpa = std.testing.allocator;
    const source = "fn f() void {\n    var a: u32 = 0;\n    var b: u32 = 0;\n}\n";
    var tree = try Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);

    var var_tokens: [2]Ast.TokenIndex = undefined;
    var count: usize = 0;
    for (0..tree.tokens.len) |i| {
        if (tree.tokenTag(@intCast(i)) == .keyword_var and count < var_tokens.len) {
            var_tokens[count] = @intCast(i);
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    const increments = [_]Increment{
        .{ .token = var_tokens[1], .points = 1, .reason = "b" },
        .{ .token = var_tokens[0], .points = 1, .reason = "a" },
    };

    try std.testing.expectEqual(@as(?usize, 2), topLine(&tree, &increments));
}

test "topLine returns null for no increments" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "fn f() void {}", .zig);
    defer tree.deinit(gpa);

    try std.testing.expectEqual(@as(?usize, null), topLine(&tree, &.{}));
}

test "returns an empty slice when there are no increments" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "fn f() void {}", .zig);
    defer tree.deinit(gpa);

    const spans = try buildSpans(gpa, &tree, &.{}, 4);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}
