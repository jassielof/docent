//! Best-effort auto-wrap: expand over-long lines via list/call breaks.
//!
//! Works the same way as `trailing_comma.zig`, but width-driven instead of
//! count-driven and iterative: each round, find every physical line still
//! over `max_line_length`, find the calls/builtin-calls/struct-inits/
//! array-inits/fn-protos (from `ast_lists.zig`) fully contained on that
//! line, insert a trailing comma for each one not already forced, and
//! re-render with `Ast.render`. Repeat until no line is over budget or
//! nothing more can be forced. Because `Ast.render` does the actual
//! line-breaking, every round's output is genuinely `zig fmt`-shaped —
//! correct indentation, asm's 2-space delta, array bin-packing — none of
//! which this pass computes itself.
//!
//! Not in scope: reflowing a line that's long for reasons no list here can
//! fix (e.g. a single very long identifier, or a binary expression with no
//! wrappable list at all) — those are left as-is, same as before.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const ast_lists = @import("ast_lists.zig");

/// Upper bound on re-render rounds. Each round strictly reduces the set of
/// forceable lists (a forced list can never become un-forced), so this is a
/// generous safety net against pathological input, not an expected ceiling.
const max_iterations: usize = 25;

test "wraps overlong call lists" {
    const gpa = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\
        \\pub fn example(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32, h: i32) i32 {
        \\    return a + b + c + d + e + f + g + h;
        \\}
        \\
        \\pub fn short(x: i32) i32 {
        \\    return x;
        \\}
        \\
    ;
    const expected =
        \\const std = @import("std");
        \\
        \\pub fn example(
        \\    a: i32,
        \\    b: i32,
        \\    c: i32,
        \\    d: i32,
        \\    e: i32,
        \\    f: i32,
        \\    g: i32,
        \\    h: i32,
        \\) i32 {
        \\    return a + b + c + d + e + f + g + h;
        \\}
        \\
        \\pub fn short(x: i32) i32 {
        \\    return x;
        \\}
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        input,
        60,
        .zig,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(expected, formatted_expected);
}

test "leaves short lines unchanged" {
    const gpa = std.testing.allocator;
    const expected =
        \\pub fn short(x: i32) i32 {
        \\    return x;
        \\}
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        expected,
        100,
        .zig,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        100,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(expected, formatted_expected);
}

test "wraps a call nested inside an if-condition, not the condition itself" {
    const gpa = std.testing.allocator;
    // `if (...)`, `while (...)`, and grouping parens aren't call/builtin
    // nodes in the AST at all, so `ast_lists.collect` never surfaces them
    // as candidates — only the real call nested inside gets found.
    const input =
        \\fn check(tree: anytype) void {
        \\    if (array_type_guard.findPathologicalArrayType(&tree, array_type_guard.default_max_length_nesting)) |pathological| {
        \\        _ = pathological;
        \\    }
        \\}
        \\
    ;
    const expected =
        \\fn check(tree: anytype) void {
        \\    if (array_type_guard.findPathologicalArrayType(
        \\        &tree,
        \\        array_type_guard.default_max_length_nesting,
        \\    )) |pathological| {
        \\        _ = pathological;
        \\    }
        \\}
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        input,
        60,
        .zig,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(expected, formatted_expected);
}

test "leaves an overlong if/while/switch condition alone when it holds no call to wrap" {
    const gpa = std.testing.allocator;
    const expected =
        \\fn pick(args: anytype, cfg: anytype) []const u8 {
        \\    return if (args.deps) &.{} else if (args.positionals.len > 0) args.positionals else cfg.check.include;
        \\}
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        expected,
        60,
        .zig,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(expected, formatted_expected);
}

test "leaves callconv/align/linksection/addrspace clauses alone, even overlong" {
    const gpa = std.testing.allocator;
    // These aren't call-expression nodes in the AST — `align`/`callconv`/
    // `linksection`/`addrspace` are fields directly on the var-decl/
    // fn-proto node, not `.call` nodes — so they're never even considered.
    const expected =
        \\fn foo() callconv(some_really_long_calling_convention_identifier_value_ok) void {}
        \\var x: u8 align(some_really_long_alignment_expression_value_used_here_ok) = 0;
        \\var y: u8 linksection(some_really_long_link_section_name_string_value_here) = 0;
        \\var z: u8 addrspace(some_really_long_address_space_identifier_value_here_ok) = 0;
        \\const E = enum(some_really_long_backing_integer_type_name_value_here_ok) {};
        \\const S = packed struct(some_really_long_backing_integer_type_name_value_ok) {};
        \\const U = union(some_really_long_tag_type_name_value_used_here_ok) {};
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        expected,
        60,
        .zig,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(expected, formatted_expected);
}

test "wraps a call nested inside an align() clause, not the clause itself" {
    const gpa = std.testing.allocator;
    const input =
        \\var x: u8 align(computeAlignment(some_argument, another_argument_here)) = 0;
        \\
    ;
    const expected =
        \\var x: u8 align(computeAlignment(
        \\    some_argument,
        \\    another_argument_here,
        \\)) = 0;
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        input,
        60,
        .zig,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(expected, formatted_expected);
}

test "wraps the outer bracket rather than a call nested inside an index/slice" {
    const gpa = std.testing.allocator;
    // Regression test for `std/crypto/tls.zig`: `Ast.render` always breaks
    // at the bracket itself for a call nested directly inside `[...]`
    // indexing, never the inner call — and it decides that on its own.
    const input =
        \\fn foo(write_bytes: []u8, i: usize, remaining: u128, head_mask: u8, bit_shift: u3) void {
        \\    write_bytes[@intCast(i)] |= @as(u8, @intCast(@as(u128, @bitCast(remaining)) & head_mask)) << bit_shift;
        \\}
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        input,
        100,
        .zig,
    );
    defer gpa.free(formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        formatted,
        100,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(formatted, formatted_expected);
}

test "un-indents a call wrapped on a continuation line to the statement's own level" {
    const gpa = std.testing.allocator;
    // Regression test for `std/bit_set.zig` and `std/crypto/25519/
    // edwards25519.zig`: the wrapped call's line only continues the
    // previous line's `++`/method-chain expression. `Ast.render` computes
    // indentation from real AST depth, so this is never a special case for
    // it the way it was for the old line-scanning heuristic.
    const input =
        \\fn foo() void {
        \\    @compileError("prefix " ++
        \\        callThatNeedsWrappingRightNow(argument_one, argument_two, argument_three));
        \\}
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        input,
        60,
        .zig,
    );
    defer gpa.free(formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        formatted,
        60,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(formatted, formatted_expected);
}

test "a comment ending in a period wraps the same as any other overlong line" {
    const gpa = std.testing.allocator;
    // Regression test: the old line-scanning heuristic misread a comment's
    // ordinary full stop as code ending in an operator. Comments aren't
    // part of the AST at all here, so there's no text to misread.
    const input =
        \\fn foo() void {
        \\    // A comment that, like most English sentences, ends in a period.
        \\    return callThatNeedsWrappingRightNow(argument_one, argument_two, argument_three);
        \\}
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        input,
        60,
        .zig,
    );
    defer gpa.free(formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        formatted,
        60,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(formatted, formatted_expected);
}

test "a leading-dot switch prong wraps at the normal (non-continuation) level" {
    const gpa = std.testing.allocator;
    // Regression test for `compiler/aro/aro/Target.zig`: `.sparc => ...` is
    // shaped like a leading-dot method-chain continuation but isn't one.
    const input =
        \\fn foo(x: Tag) u8 {
        \\    switch (x) {
        \\        .sparc => if (callThatNeedsWrappingRightNow(argument_one, argument_two, argument_three)) return 16 else return 8,
        \\        else => return 8,
        \\    }
        \\}
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        input,
        60,
        .zig,
    );
    defer gpa.free(formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        formatted,
        60,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(formatted, formatted_expected);
}

const format_test_assertions = @import("format_test_assertions.zig");

/// Wraps over-long lines by expanding calls/builtin-calls/struct-inits/
/// array-inits/fn-protos found on them. Caller owns the returned slice.
pub fn autoWrap(
    gpa: Allocator,
    input: []const u8,
    max_line_length: u32,
    mode: Ast.Mode,
) Allocator.Error![]u8 {
    var current = try gpa.dupe(u8, input);

    var iteration: usize = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        const next = try oneIteration(
            gpa,
            current,
            max_line_length,
            mode,
        ) orelse break;
        gpa.free(current);
        current = next;
    }

    return current;
}

/// Runs one render round: finds overlong lines, forces every list fully
/// contained on one of them that isn't already forced, and re-renders.
/// Returns `null` when nothing more can be (or needs to be) forced.
fn oneIteration(
    gpa: Allocator,
    current: []const u8,
    max_line_length: u32,
    mode: Ast.Mode,
) Allocator.Error!?[]u8 {
    const source_z = try gpa.dupeZ(u8, current);
    defer gpa.free(source_z);

    var tree = try Ast.parse(
        gpa,
        source_z,
        mode,
    );
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return null;

    const overlong = try findOverlongRanges(
        gpa,
        current,
        max_line_length,
    );
    defer gpa.free(overlong);
    if (overlong.len == 0) return null;

    const lists = try ast_lists.collect(gpa, &tree);
    defer gpa.free(lists);

    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(gpa);
    var seen_offsets: std.AutoHashMap(usize, void) = .init(gpa);
    defer seen_offsets.deinit();

    for (overlong) |range| {
        for (lists) |list_node| {
            if (list_node.has_trailing_comma) continue;
            const open_byte = tree.tokenStart(list_node.open);
            const close_byte = tree.tokenStart(list_node.close);
            if (open_byte >= range.start and close_byte < range.end) {
                if ((try seen_offsets.fetchPut(close_byte, {})) == null) {
                    try offsets.append(gpa, close_byte);
                }
            }
        }
    }

    if (offsets.items.len == 0) return null;

    std.mem.sort(
        usize,
        offsets.items,
        {},
        std.sort.asc(usize),
    );

    const patched = try ast_lists.applyInsertions(
        gpa,
        current,
        offsets.items,
    );
    defer gpa.free(patched);

    return try ast_lists.renderSource(
        gpa,
        patched,
        mode,
    );
}

const LineRange = struct { start: usize, end: usize };

/// Byte ranges (start of line, index of its `\n` or end-of-source) of every
/// physical line in `source` longer than `max_line_length`. Caller owns the
/// returned slice.
fn findOverlongRanges(
    gpa: Allocator,
    source: []const u8,
    max_line_length: u32,
) Allocator.Error![]LineRange {
    var out: std.ArrayList(LineRange) = .empty;
    errdefer out.deinit(gpa);

    var line_start: usize = 0;
    while (line_start < source.len) {
        const line_end = mem.indexOfScalarPos(
            u8,
            source,
            line_start,
            '\n',
        ) orelse source.len;
        if (line_end - line_start > max_line_length) {
            try out.append(gpa, .{ .start = line_start, .end = line_end });
        }
        line_start = if (line_end < source.len) line_end + 1 else source.len;
    }

    return out.toOwnedSlice(gpa);
}
