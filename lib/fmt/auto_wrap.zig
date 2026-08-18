//! Best-effort auto-wrap: expand over-long lines via list/call breaks.
//!
//! Operates on already-rendered Zig source. When a physical line exceeds `max_line_length`, tries the same list-expansion strategy as `trailing_comma.zig` with a lower threshold (break even 1–2 item lists if needed). Leaves lines unchanged when nothing safe can be broken.
//!
//! Not in scope: binary-expression reflow, comment wrapping, or paragraph reflow of prose.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const format_test_assertions = @import("format_test_assertions.zig");

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
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
    );
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
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
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        100,
    );
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "wraps a call nested inside an if-condition, not the condition itself" {
    const gpa = std.testing.allocator;
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
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
    );
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
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
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
    );
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "wraps the call nested inside a grouping paren, not the grouping itself" {
    const gpa = std.testing.allocator;
    const input =
        \\fn flag(ctx: anytype, cfg: anytype) bool {
        \\    const include_private = (ctx.boolFlag("include-private") orelse false) or cfg.typeset.include_private;
        \\    return include_private;
        \\}
        \\
    ;
    const expected =
        \\fn flag(ctx: anytype, cfg: anytype) bool {
        \\    const include_private = (ctx.boolFlag(
        \\        "include-private",
        \\    ) orelse false) or cfg.typeset.include_private;
        \\    return include_private;
        \\}
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        input,
        100,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        100,
    );
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "leaves overlong multiline string literal lines untouched" {
    const gpa = std.testing.allocator;
    const expected =
        \\const msg =
        \\    \\Some very long line inside a multiline string literal that happens to contain (parentheses, and a comma)
        \\;
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        expected,
        60,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
    );
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "leaves callconv/align/linksection/addrspace clauses alone, even overlong" {
    const gpa = std.testing.allocator;
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
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
    );
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
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
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
    );
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "wraps a call outside an index/slice bracket rather than the bracketed one" {
    const gpa = std.testing.allocator;
    // `zig fmt` insists on breaking at the bracket itself for a call nested
    // directly inside `[...]` (it never leaves the inner call wrapped in
    // place there), so wrapping `@intCast(i)` here would be immediately
    // undone by a real `zig fmt` pass. The `@as(...)` call after the
    // bracket has no such restriction and is the correct, stable target.
    const input =
        \\fn foo(write_bytes: []u8, i: usize, remaining: u128, head_mask: u8, bit_shift: u3) void {
        \\    write_bytes[@intCast(i)] |= @as(u8, @intCast(@as(u128, @bitCast(remaining)) & head_mask)) << bit_shift;
        \\}
        \\
    ;
    const expected =
        \\fn foo(write_bytes: []u8, i: usize, remaining: u128, head_mask: u8, bit_shift: u3) void {
        \\    write_bytes[@intCast(i)] |= @as(
        \\        u8,
        \\        @intCast(@as(u128, @bitCast(remaining)) & head_mask),
        \\    ) << bit_shift;
        \\}
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        input,
        100,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        100,
    );
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "leaves an overlong hand-packed row of several calls alone" {
    const gpa = std.testing.allocator;
    // Same rationale as the bracket-instability test above: this pass sees
    // one physical line at a time, so wrapping the first call in a row
    // shared with others would splice its output into the rest of the row.
    const expected =
        \\const arx_steps = [_]QuarterRound{
        \\    Rp(4, 0, 12, 7),   Rp(8, 4, 0, 9),    Rp(12, 8, 4, 13),   Rp(0, 12, 8, 18),
        \\};
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        expected,
        60,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
    );
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "uses asm's 2-space indent delta when wrapping inside it" {
    const gpa = std.testing.allocator;
    // `Ast/Render.zig` renders everything inside `asm (...)` /
    // `asm volatile (...)` with a 2-space indent step instead of the usual
    // 4 (`asm_indent_delta` vs. `indent_delta`). Uses a real call (rather
    // than a `.{...}` clobber list) since `findBestBreak` never selects a
    // `.{` literal as a wrap candidate — that expansion belongs to
    // `trailing_comma.zig`, which has its own equivalent asm-indent test.
    const input =
        \\pub fn syscall0(number: SYS) u64 {
        \\    return asm volatile ("syscall"
        \\        : [ret] "={rax}" (-> u64),
        \\        : [number] "{rax}" (computeSyscallNumber(number, extra_one, extra_two)),
        \\        : .{ .rcx = true, .r11 = true, .memory = true });
        \\}
        \\
    ;
    const expected =
        \\pub fn syscall0(number: SYS) u64 {
        \\    return asm volatile ("syscall"
        \\        : [ret] "={rax}" (-> u64),
        \\        : [number] "{rax}" (computeSyscallNumber(
        \\          number,
        \\          extra_one,
        \\          extra_two,
        \\        )),
        \\        : .{ .rcx = true, .r11 = true, .memory = true });
        \\}
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        input,
        60,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
    );
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "an apostrophe in asm template text doesn't desync later line indices" {
    const gpa = std.testing.allocator;
    // Regression test: `computeAsmLineFlags` used to scan the whole file as
    // one character stream. A bare `'` inside assembly template/comment
    // text (an English contraction, not a char literal) made it search for
    // a closing quote arbitrarily far forward, skipping embedded newlines
    // without counting them and desyncing every later line's index from
    // its real line number — so a call needing to wrap after it got the
    // wrong (4-space, "not in asm") indent instead of asm's 2-space one.
    const input =
        \\pub fn syscall0(number: SYS) u64 {
        \\    return asm volatile (
        \\        \\ # Clear the child's %%o0
        \\        \\ syscall
        \\        : [ret] "={rax}" (-> u64),
        \\        : [number] "{rax}" (computeSyscallNumber(number, extra_one, extra_two)),
        \\        : .{ .rcx = true, .r11 = true, .memory = true });
        \\}
        \\
    ;
    const expected =
        \\pub fn syscall0(number: SYS) u64 {
        \\    return asm volatile (
        \\        \\ # Clear the child's %%o0
        \\        \\ syscall
        \\        : [ret] "={rax}" (-> u64),
        \\        : [number] "{rax}" (computeSyscallNumber(
        \\          number,
        \\          extra_one,
        \\          extra_two,
        \\        )),
        \\        : .{ .rcx = true, .r11 = true, .memory = true });
        \\}
        \\
    ;

    const formatted = try autoWrap(
        gpa,
        input,
        60,
    );
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try autoWrap(
        gpa,
        expected,
        60,
    );
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

/// Wraps over-long lines by expanding `(...)` / `{...}` lists. Caller owns the returned slice.
pub fn autoWrap(
    gpa: Allocator,
    input: []const u8,
    max_line_length: u32,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    try output.ensureTotalCapacity(gpa, input.len * 2);

    const asm_line_flags = try computeAsmLineFlags(gpa, input);
    defer gpa.free(asm_line_flags);

    var line_start: usize = 0;
    var line_idx: usize = 0;
    while (line_start < input.len) {
        const line_end = mem.indexOfScalar(
            u8,
            input[line_start..],
            '\n',
        ) orelse input.len - line_start;
        const full_line = input[line_start .. line_start + line_end];
        line_start += line_end + 1;

        if (full_line.len > max_line_length and !isCommentOnly(full_line) and !isMultilineStringLine(full_line)) {
            const indent_len = leadingSpaces(full_line);
            // `Ast/Render.zig` renders everything inside `asm (...)` /
            // `asm volatile (...)` with a 2-space indent step instead of
            // the usual 4 (its own `asm_indent_delta` vs. `indent_delta`).
            const indent_step: usize = if (line_idx < asm_line_flags.len and asm_line_flags[line_idx]) 2 else 4;
            var scratch: std.ArrayList(u8) = .empty;
            defer scratch.deinit(gpa);
            try expandOverlong(
                gpa,
                &scratch,
                full_line,
                indent_len,
                max_line_length,
                indent_step,
            );
            try output.appendSlice(gpa, scratch.items);
        } else {
            try output.appendSlice(gpa, full_line);
        }

        if (line_start <= input.len) try output.append(gpa, '\n');
        line_idx += 1;
    }

    return output.toOwnedSlice(gpa);
}

fn expandOverlong(
    gpa: Allocator,
    output: *std.ArrayList(u8),
    line: []const u8,
    base_indent: usize,
    max_line_length: u32,
    indent_step: usize,
) !void {
    // A physical line with more than one top-level (bracket-depth-0)
    // comma-separated piece is either a `zig fmt`-bin-packed row of a
    // larger multi-line list or a call sharing a row with unrelated
    // sibling content. Wrapping just the one construct this pass can see
    // would splice its output into text it doesn't understand is part of
    // the same row, so leave the whole line untouched instead.
    if (!hasMultipleTopLevelSegments(line)) {
        // Prefer the outermost breakable construct that reduces width.
        if (findBestBreak(line)) |break_at| {
            const c = line[break_at];
            const close: u8 = if (c == '(') ')' else '}';
            if (findMatchingClose(
                line,
                break_at,
                c,
                close,
            )) |close_pos| {
                const inner = line[break_at + 1 .. close_pos];
                if (inner.len > 0 and !hasTrailingComma(inner)) {
                    const items = try splitTopLevel(gpa, inner);
                    defer gpa.free(items);

                    if (items.len >= 1) {
                        try output.appendSlice(gpa, line[0..break_at]);
                        try output.append(gpa, c);
                        try output.append(gpa, '\n');

                        const item_indent = base_indent + indent_step;
                        for (items) |item| {
                            const trimmed = mem.trim(
                                u8,
                                item,
                                " \t",
                            );
                            if (trimmed.len == 0) continue;
                            try appendSpaces(
                                gpa,
                                output,
                                item_indent,
                            );
                            // Recurse if the item itself is still over budget.
                            if (item_indent + trimmed.len > max_line_length) {
                                try expandOverlong(
                                    gpa,
                                    output,
                                    trimmed,
                                    item_indent,
                                    max_line_length,
                                    indent_step,
                                );
                            } else {
                                try output.appendSlice(gpa, trimmed);
                            }
                            try output.append(gpa, ',');
                            try output.append(gpa, '\n');
                        }

                        try appendSpaces(
                            gpa,
                            output,
                            base_indent,
                        );
                        try output.append(gpa, close);
                        try output.appendSlice(gpa, line[close_pos + 1 ..]);
                        return;
                    }
                }
            }
        }
    }

    // Nothing safe to break — leave the line as-is.
    try output.appendSlice(gpa, line);
}

/// Reports whether `line` contains more than one non-empty, comma-separated
/// piece at bracket depth 0 (i.e. outside all `(`/`{`/`[` nesting). See
/// `trailing_comma.zig`'s copy of this function for the full rationale.
fn hasMultipleTopLevelSegments(line: []const u8) bool {
    var depth: usize = 0;
    var seg_start: usize = 0;
    var non_empty_segments: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') break;
        if (c == '\'' or c == '"') {
            i = skipStringLiteral(line, i) - 1;
            continue;
        }
        switch (c) {
            '(', '{', '[' => depth += 1,
            ')', '}', ']' => {
                if (depth > 0) depth -= 1;
            },
            ',' => {
                if (depth == 0) {
                    if (mem.trim(u8, line[seg_start..i], " \t").len > 0) non_empty_segments += 1;
                    seg_start = i + 1;
                    if (non_empty_segments > 1) return true;
                }
            },
            else => {},
        }
    }
    if (mem.trim(u8, line[seg_start..], " \t").len > 0) non_empty_segments += 1;
    return non_empty_segments > 1;
}

/// Computes, for each physical line of `input`, whether that line's start
/// falls inside an still-open `asm (...)` / `asm volatile (...)` expression.
/// Caller owns the returned slice.
///
/// Scans one bounded physical line at a time (skipping multiline string
/// literal lines outright, same as `isMultilineStringLine` elsewhere in
/// this file) rather than treating `input` as one long character stream.
/// An unmatched `'` inside assembly template text (e.g. an English
/// contraction in a comment, `the child's %o0`) would otherwise make
/// `skipStringLiteral` search for its closing quote arbitrarily far
/// forward, jumping over embedded newlines without counting them and
/// desynchronizing every later line's index from its true line number.
fn computeAsmLineFlags(gpa: Allocator, input: []const u8) Allocator.Error![]bool {
    var line_count: usize = 1;
    for (input) |c| {
        if (c == '\n') line_count += 1;
    }
    const flags = try gpa.alloc(bool, line_count);
    @memset(flags, false);

    var depth: usize = 0;
    var line_start: usize = 0;
    var line_idx: usize = 0;
    while (line_idx < flags.len) : (line_idx += 1) {
        const line_end = mem.indexOfScalarPos(u8, input, line_start, '\n') orelse input.len;
        const line = input[line_start..line_end];
        flags[line_idx] = depth > 0;

        if (!isMultilineStringLine(line)) {
            var i: usize = 0;
            while (i < line.len) : (i += 1) {
                const c = line[i];

                if (c == '/' and i + 1 < line.len and line[i + 1] == '/') break;

                if (c == '\'' or c == '"') {
                    i = skipStringLiteral(line, i) - 1;
                    continue;
                }

                if (depth == 0) {
                    if (matchAsmOpenParen(line, i)) |paren_pos| {
                        depth = 1;
                        i = paren_pos;
                        flags[line_idx] = true;
                        continue;
                    }
                } else {
                    if (c == '(') depth += 1;
                    if (c == ')' and depth > 0) depth -= 1;
                }
            }
        }

        if (line_end >= input.len) break;
        line_start = line_end + 1;
    }

    return flags;
}

/// If `text[pos..]` starts with the whole word `asm`, optionally followed
/// by whitespace and the whole word `volatile`, then whitespace and `(`,
/// returns the index of that `(`. Otherwise null.
fn matchAsmOpenParen(text: []const u8, pos: usize) ?usize {
    if (!mem.startsWith(u8, text[pos..], "asm")) return null;
    if (pos > 0 and isIdentChar(text[pos - 1])) return null;
    var i = pos + 3;
    if (i < text.len and isIdentChar(text[i])) return null;

    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;

    if (mem.startsWith(u8, text[i..], "volatile")) {
        const after = i + "volatile".len;
        if (after < text.len and isIdentChar(text[after])) return null;
        i = after;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    }

    if (i < text.len and text[i] == '(') return i;
    return null;
}

/// Finds the leftmost `(...)` or `{...}` whose expansion would help: a real
/// call/parameter list (or `.{` literal) with non-empty, non-trailing-comma
/// content. Grouping and control-flow parens (`if (`, `while (`, `(a and
/// b)`, ...) are skipped — they can't take a trailing comma — but scanning
/// continues inside them since the real wrap target is often a call nested
/// in the condition. Calls nested inside an still-open `[...]` index/slice
/// are skipped too and NOT dived into: `zig fmt` prefers breaking at the
/// bracket itself (which takes no trailing comma, a different shape than
/// what this pass produces), so wrapping the inner call would just be
/// reformatted right back by a real `zig fmt` pass — leave the line alone.
fn findBestBreak(line: []const u8) ?usize {
    var pos: usize = 0;
    var bracket_depth: usize = 0;
    while (pos < line.len) {
        const c = line[pos];

        if (c == '/' and pos + 1 < line.len and line[pos + 1] == '/') break;

        if (c == '\'' or c == '"') {
            pos = skipStringLiteral(line, pos);
            continue;
        }

        if (c == '[') {
            bracket_depth += 1;
            pos += 1;
            continue;
        }
        if (c == ']') {
            if (bracket_depth > 0) bracket_depth -= 1;
            pos += 1;
            continue;
        }

        if (c == '(' or c == '{') {
            // Skip `.{` anonymous struct start for `{` after `.`
            if (c == '{' and pos > 0 and line[pos - 1] == '.') {
                if (findMatchingClose(
                    line,
                    pos,
                    '{',
                    '}',
                )) |close_pos| {
                    pos = close_pos + 1;
                    continue;
                }
            }

            if (c == '(' and (bracket_depth > 0 or !isCallParen(line, pos))) {
                pos += 1;
                continue;
            }

            const close: u8 = if (c == '(') ')' else '}';
            if (findMatchingClose(
                line,
                pos,
                c,
                close,
            )) |close_pos| {
                const inner = line[pos + 1 .. close_pos];
                if (inner.len > 0 and !hasTrailingComma(inner) and containsTopLevelCommaOrContent(inner)) {
                    return pos;
                }
                pos = close_pos + 1;
                continue;
            }
        }

        pos += 1;
    }
    return null;
}

/// Reports whether the `(` at `pos` opens a call or parameter list (as
/// opposed to a control-flow condition or a grouping expression), based on
/// the character immediately before it. Canonical Zig formatting never puts
/// a space before a call's opening paren, but always puts one before `if (`,
/// `while (`, `switch (`, `for (`, and bare grouping parens.
fn isCallParen(line: []const u8, pos: usize) bool {
    if (pos == 0) return false;
    switch (line[pos - 1]) {
        ')', ']' => return true, // chained call/index result, never a keyword clause
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => return false,
    }

    // `align(`, `callconv(`, `linksection(`, `addrspace(`, and the
    // backing/tag-type clauses `enum(`, `struct(`, `union(` all use
    // call-like syntax but each take exactly one required expression —
    // unlike a real call or parameter list, the parser rejects a trailing
    // comma there.
    var start = pos - 1;
    while (start > 0 and isIdentChar(line[start - 1])) : (start -= 1) {}
    return !isSingleExprClauseKeyword(line[start..pos]);
}

fn isIdentChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}

fn isSingleExprClauseKeyword(ident: []const u8) bool {
    const keywords = [_][]const u8{
        "align",
        "callconv",
        "linksection",
        "addrspace",
        "enum",
        "struct",
        "union",
    };
    for (keywords) |kw| {
        if (mem.eql(u8, ident, kw)) return true;
    }
    return false;
}

fn containsTopLevelCommaOrContent(inner: []const u8) bool {
    const trimmed = mem.trim(
        u8,
        inner,
        " \t",
    );
    return trimmed.len > 0;
}

fn isCommentOnly(line: []const u8) bool {
    const trimmed = mem.trim(
        u8,
        line,
        " \t",
    );
    return trimmed.len >= 2 and trimmed[0] == '/' and (trimmed[1] == '/' or trimmed[1] == '!');
}

/// Reports whether `line` is a continuation line of a Zig multiline string
/// literal (`\\...`). These must never be split or rejoined: every line of
/// such a literal is syntactically required to start with its own `\\`
/// prefix, and generic paren/brace matching inside the string content would
/// otherwise corrupt it.
fn isMultilineStringLine(line: []const u8) bool {
    const rest = line[leadingSpaces(line)..];
    return rest.len >= 2 and rest[0] == '\\' and rest[1] == '\\';
}

fn splitTopLevel(gpa: Allocator, inner: []const u8) ![][]const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(gpa);

    var depth_paren: usize = 0;
    var depth_brace: usize = 0;
    var start: usize = 0;
    var i: usize = 0;

    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c == '\'' or c == '"') {
            i = skipStringLiteral(inner, i) - 1;
            continue;
        }
        switch (c) {
            '(' => depth_paren += 1,
            ')' => {
                if (depth_paren > 0) depth_paren -= 1;
            },
            '{' => depth_brace += 1,
            '}' => {
                if (depth_brace > 0) depth_brace -= 1;
            },
            ',' => {
                if (depth_paren == 0 and depth_brace == 0) {
                    try items.append(gpa, inner[start..i]);
                    start = i + 1;
                }
            },
            else => {},
        }
    }

    if (start < inner.len) {
        try items.append(gpa, inner[start..]);
    } else if (items.items.len > 0) {
        // Trailing comma already handled by hasTrailingComma guard.
    } else if (mem.trim(
        u8,
        inner,
        " \t",
    ).len > 0) {
        try items.append(gpa, inner);
    }

    return items.toOwnedSlice(gpa);
}

fn appendSpaces(
    gpa: Allocator,
    output: *std.ArrayList(u8),
    count: usize,
) !void {
    var j: usize = 0;
    while (j < count) : (j += 1) {
        try output.append(gpa, ' ');
    }
}

fn leadingSpaces(line: []const u8) usize {
    for (line, 0..) |c, i| {
        if (c != ' ') return i;
    }
    return line.len;
}

fn findMatchingClose(
    line: []const u8,
    start: usize,
    open: u8,
    close: u8,
) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\'' or c == '"') {
            i = skipStringLiteral(line, i) - 1;
            continue;
        }
        if (c == open) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn hasTrailingComma(inner: []const u8) bool {
    const trimmed = mem.trimEnd(
        u8,
        inner,
        " ",
    );
    return trimmed.len > 0 and trimmed[trimmed.len - 1] == ',';
}

fn skipStringLiteral(line: []const u8, start: usize) usize {
    const quote = line[start];
    var i = start + 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == quote) return i + 1;
    }
    return line.len;
}
