//! The trailing_comma namespace forces comma-delimited lists with 3 or more
//! items onto one-per-line with a trailing comma, matching what Zig
//! suggests as a style convention. See
//! <https://ziglang.org/documentation/0.16.0/#Whitespace>.
//!
//! This works entirely from the AST: `ast_lists.zig` finds every call,
//! builtin-call, struct/array-init, and fn-proto list in the tree, and any
//! list with 3+ items and no trailing comma yet gets one inserted at its
//! exact token position. The modified source is then re-parsed and handed
//! to `Ast.render` — the same renderer `zig fmt` itself uses — so the
//! actual line-breaking, indentation, and bin-packing is never
//! re-implemented here; it's simply requested.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const ast_lists = @import("ast_lists.zig");
const format_test_assertions = @import("format_test_assertions.zig");

test "adds trailing commas to multiline lists" {
    const gpa = std.testing.allocator;
    const input =
        \\fn foo(a: u8, b: u8, c: u8) void {
        \\    _ = a;
        \\    _ = b;
        \\    _ = c;
        \\}
        \\
        \\fn bar(x: u8, y: u8) void {
        \\    _ = x;
        \\    _ = y;
        \\}
        \\
        \\fn baz(one: u8, two: u8, three: u8, four: u8) void {
        \\    _ = one;
        \\    _ = two;
        \\    _ = three;
        \\    _ = four;
        \\}
        \\
        \\fn quux(a: u8, b: u8, c: u8) void {
        \\    _ = a;
        \\    _ = b;
        \\    _ = c;
        \\}
        \\
        \\fn example() void {
        \\    const a = 1;
        \\    const b = 2;
        \\    const c = 3;
        \\
        \\    foo(a, b, c);
        \\
        \\    bar("x", "y");
        \\
        \\    baz("one", "two", "three", "four");
        \\
        \\    const s = .{ .a = 1, .b = 2, .c = 3 };
        \\    _ = s;
        \\
        \\    const arr = [_]u8{ 1, 2, 3 };
        \\    _ = arr;
        \\
        \\    const nested = foo(bar("x", "y", "z"), "d", "e");
        \\    _ = nested;
        \\
        \\    const two_fields = .{ .x = 1, .y = 2 };
        \\    _ = two_fields;
        \\
        \\    const msg = "hello, world, foo";
        \\    _ = msg;
        \\
        \\    quux(
        \\        a,
        \\        b,
        \\        c,
        \\    );
        \\}
        \\
    ;
    const expected =
        \\fn foo(
        \\    a: u8,
        \\    b: u8,
        \\    c: u8,
        \\) void {
        \\    _ = a;
        \\    _ = b;
        \\    _ = c;
        \\}
        \\
        \\fn bar(x: u8, y: u8) void {
        \\    _ = x;
        \\    _ = y;
        \\}
        \\
        \\fn baz(
        \\    one: u8,
        \\    two: u8,
        \\    three: u8,
        \\    four: u8,
        \\) void {
        \\    _ = one;
        \\    _ = two;
        \\    _ = three;
        \\    _ = four;
        \\}
        \\
        \\fn quux(
        \\    a: u8,
        \\    b: u8,
        \\    c: u8,
        \\) void {
        \\    _ = a;
        \\    _ = b;
        \\    _ = c;
        \\}
        \\
        \\fn example() void {
        \\    const a = 1;
        \\    const b = 2;
        \\    const c = 3;
        \\
        \\    foo(
        \\        a,
        \\        b,
        \\        c,
        \\    );
        \\
        \\    bar("x", "y");
        \\
        \\    baz(
        \\        "one",
        \\        "two",
        \\        "three",
        \\        "four",
        \\    );
        \\
        \\    const s = .{
        \\        .a = 1,
        \\        .b = 2,
        \\        .c = 3,
        \\    };
        \\    _ = s;
        \\
        \\    const arr = [_]u8{
        \\        1,
        \\        2,
        \\        3,
        \\    };
        \\    _ = arr;
        \\
        \\    const nested = foo(
        \\        bar(
        \\            "x",
        \\            "y",
        \\            "z",
        \\        ),
        \\        "d",
        \\        "e",
        \\    );
        \\    _ = nested;
        \\
        \\    const two_fields = .{ .x = 1, .y = 2 };
        \\    _ = two_fields;
        \\
        \\    const msg = "hello, world, foo";
        \\    _ = msg;
        \\
        \\    quux(
        \\        a,
        \\        b,
        \\        c,
        \\    );
        \\}
        \\
    ;

    const formatted = try addTrailingCommas(
        gpa,
        input,
        .zig,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);

    const formatted_expected = try addTrailingCommas(
        gpa,
        expected,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(expected, formatted_expected);
}

test "leaves a call nested inside an index/slice bracket alone" {
    const gpa = std.testing.allocator;
    // `zig fmt` always breaks at the bracket itself for a call nested
    // directly inside `[...]` indexing — not at the call's own parens.
    // `Ast.render` decides that on its own once the call has a trailing
    // comma; nothing about docent's own logic needs to know that rule.
    const input =
        \\var result: [std.mem.alignForwardAnyAlign(usize, len, Hmac.mac_length)]u8 = undefined;
        \\
    ;

    const formatted = try addTrailingCommas(
        gpa,
        input,
        .zig,
    );
    defer gpa.free(formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try addTrailingCommas(
        gpa,
        formatted,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(formatted, formatted_expected);
}

test "leaves a hand-packed row of several calls in an already-multiline list alone" {
    const gpa = std.testing.allocator;
    // `Rp(...)` is a direct element of the outer array-init. It has 4 items
    // itself, but forcing it independently would fight `Ast.render`'s own
    // bin-packing of the (already trailing-comma'd) outer list — so this
    // pass never looks at array/struct-init elements on their own.
    const input =
        \\const arx_steps = [_]QuarterRound{
        \\    Rp(4, 0, 12, 7), Rp(8, 4, 0, 9), Rp(12, 8, 4, 13), Rp(0, 12, 8, 18),
        \\};
        \\
    ;

    const formatted = try addTrailingCommas(
        gpa,
        input,
        .zig,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);

    const formatted_expected = try addTrailingCommas(
        gpa,
        formatted,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(input, formatted_expected);
}

test "un-indents a call expanded on a continuation line to the statement's own level" {
    const gpa = std.testing.allocator;
    // Regression test for `std/bit_set.zig`: the wrapped call sits on a
    // line that only continues the `++` chain from the statement above.
    // Indenting from rendered text (as the old line-scanning pass did)
    // guesses wrong here; deferring to `Ast.render` never can, because it
    // computes indentation from the real AST depth, not from a physical
    // line's own (already-shifted) leading whitespace.
    const input =
        \\fn foo() void {
        \\    @compileError("prefix " ++
        \\        callThatNeedsExpanding(argument_one, argument_two, argument_three));
        \\}
        \\
    ;

    const formatted = try addTrailingCommas(
        gpa,
        input,
        .zig,
    );
    defer gpa.free(formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try addTrailingCommas(
        gpa,
        formatted,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(formatted, formatted_expected);
}

test "uses asm's 2-space indent delta for a clobber list nested inside it" {
    const gpa = std.testing.allocator;
    // `Ast/Render.zig` renders everything inside `asm (...)` /
    // `asm volatile (...)` with a 2-space indent step instead of the usual
    // 4. Deferring to `Ast.render` gets this for free.
    const input =
        \\pub fn syscall0(number: SYS) u64 {
        \\    return asm volatile ("syscall"
        \\        : [ret] "={rax}" (-> u64),
        \\        : [number] "{rax}" (@intFromEnum(number)),
        \\        : .{ .rcx = true, .r11 = true, .memory = true });
        \\}
        \\
    ;
    const expected =
        \\pub fn syscall0(number: SYS) u64 {
        \\    return asm volatile ("syscall"
        \\        : [ret] "={rax}" (-> u64),
        \\        : [number] "{rax}" (@intFromEnum(number)),
        \\        : .{
        \\          .rcx = true,
        \\          .r11 = true,
        \\          .memory = true,
        \\        });
        \\}
        \\
    ;

    const formatted = try addTrailingCommas(
        gpa,
        input,
        .zig,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);

    const formatted_expected = try addTrailingCommas(
        gpa,
        expected,
        .zig,
    );
    defer gpa.free(formatted_expected);
    try std.testing.expectEqualStrings(expected, formatted_expected);
}

test "leaves multiline string literal content unchanged" {
    const gpa = std.testing.allocator;
    const input =
        \\const template =
        \\    \\call(one, two, three);
        \\    \\.{ .first = 1, .second = 2, .third = 3 }
        \\;
    ;

    const formatted = try addTrailingCommas(
        gpa,
        input,
        .zig,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
}

/// Expands comma-delimited lists (call arguments, builtin-call arguments,
/// struct/array-init, and fn-proto parameter lists) with 3 or more items to
/// one-per-line with a trailing comma. Caller owns the returned slice.
pub fn addTrailingCommas(
    gpa: Allocator,
    input: []const u8,
    mode: Ast.Mode,
) Allocator.Error![]u8 {
    const source_z = try gpa.dupeZ(u8, input);
    defer gpa.free(source_z);

    var tree = try Ast.parse(
        gpa,
        source_z,
        mode,
    );
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return gpa.dupe(u8, input);

    const lists = try ast_lists.collect(gpa, &tree);
    defer gpa.free(lists);

    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(gpa);
    for (lists) |list_node| {
        if (list_node.item_count >= 3 and !list_node.has_trailing_comma) {
            try offsets.append(gpa, tree.tokenStart(list_node.close));
        }
    }

    if (offsets.items.len == 0) return gpa.dupe(u8, input);

    std.mem.sort(
        usize,
        offsets.items,
        {},
        std.sort.asc(usize),
    );

    const patched = try ast_lists.applyInsertions(
        gpa,
        input,
        offsets.items,
    );
    defer gpa.free(patched);

    return ast_lists.renderSource(
        gpa,
        patched,
        mode,
    );
}
