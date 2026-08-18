//! The trailing_comma namespace contains the logic to add trailing commas to lists.
//!
//! This is based on the that Zig suggests to add trailing commas, or basically break the list elements into one-per-line, when there are 3 or more items in a single-line list. See <https://ziglang.org/documentation/0.16.0/#Whitespace>.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

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

    const formatted = try addTrailingCommas(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try addTrailingCommas(gpa, expected);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "leaves multiline string literal content unchanged" {
    const gpa = std.testing.allocator;
    const input =
        \\const template =
        \\    \\call(one, two, three);
        \\    \\.{ .first = 1, .second = 2, .third = 3 }
        \\;
    ;

    const formatted = try addTrailingCommas(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

test "leaves a call nested inside an index/slice bracket alone" {
    const gpa = std.testing.allocator;
    // `zig fmt` insists on breaking at the bracket itself for a call nested
    // directly inside `[...]` (it never leaves the inner call expanded in
    // place there), so expanding `alignForwardAnyAlign(...)` here would be
    // immediately undone by a real `zig fmt` pass — leave it alone.
    const input =
        \\var result: [std.mem.alignForwardAnyAlign(usize, len, Hmac.mac_length)]u8 = undefined;
        \\
    ;

    const formatted = try addTrailingCommas(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try addTrailingCommas(gpa, formatted);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(formatted, formatted_expected);
}

test "leaves a hand-packed row of several calls on one line alone" {
    const gpa = std.testing.allocator;
    // `zig fmt` bin-packs array-init elements onto a row based on measured
    // width when the source has a trailing comma — it isn't "preserving the
    // author's line breaks" verbatim, but the effect on a line like this is
    // the same: several complete `Rp(...)` calls share one physical line.
    // Expanding the first call in place (this pass sees one physical line
    // at a time, with no notion of "row of a larger list") would splice its
    // closing `)` directly into the next call's text.
    const input =
        \\const arx_steps = [_]QuarterRound{
        \\    Rp(4, 0, 12, 7),   Rp(8, 4, 0, 9),    Rp(12, 8, 4, 13),   Rp(0, 12, 8, 18),
        \\};
        \\
    ;

    const formatted = try addTrailingCommas(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try addTrailingCommas(gpa, formatted);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(formatted, formatted_expected);
}

test "leaves a call sharing a row with other hand-aligned items alone" {
    const gpa = std.testing.allocator;
    // Same shape, different cause: `betterMatchLen(...)` alone would
    // qualify for expansion, but it shares this physical line with an
    // `if/else` item that belongs to the same enclosing `.{...}` argument
    // list — expanding just the call would leave the `if/else` text
    // dangling in front of it.
    const input =
        \\fn logMismatch(old: u16, expected_len: ?u16) void {
        \\    std.debug.print(fmt, .{
        \\        prev,                                           bytes,                            old,
        \\        if (old < expected_len) expected_len else null, betterMatchLen(old, prev, bytes),
        \\    });
        \\}
        \\
    ;

    const formatted = try addTrailingCommas(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try addTrailingCommas(gpa, formatted);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(formatted, formatted_expected);
}

test "uses asm's 2-space indent delta for a clobber list nested inside it" {
    const gpa = std.testing.allocator;
    // `Ast/Render.zig` renders everything inside `asm (...)` /
    // `asm volatile (...)` with a 2-space indent step instead of the usual
    // 4 (`asm_indent_delta` vs. `indent_delta`). A construct expanded
    // inside that scope must follow the same rule to match `zig fmt`.
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

    const formatted = try addTrailingCommas(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try addTrailingCommas(gpa, expected);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "leaves a call outside any asm block at the normal 4-space indent" {
    const gpa = std.testing.allocator;
    // Guards against the asm-tracking state leaking past the block's own
    // closing paren and misindenting unrelated code that follows it.
    const input =
        \\pub fn syscall0(number: SYS) u64 {
        \\    return asm volatile ("syscall"
        \\        : [ret] "={rax}" (-> u64),
        \\        : [number] "{rax}" (@intFromEnum(number)),
        \\        : .{ .rcx = true, .r11 = true, .memory = true });
        \\}
        \\
        \\fn quux(a: u8, b: u8, c: u8) void {
        \\    _ = a;
        \\}
        \\
        \\fn callsQuux() void {
        \\    quux(first_argument, second_argument, third_argument);
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
        \\fn quux(
        \\    a: u8,
        \\    b: u8,
        \\    c: u8,
        \\) void {
        \\    _ = a;
        \\}
        \\
        \\fn callsQuux() void {
        \\    quux(
        \\        first_argument,
        \\        second_argument,
        \\        third_argument,
        \\    );
        \\}
        \\
    ;

    const formatted = try addTrailingCommas(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try addTrailingCommas(gpa, expected);
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
    // its real line number — so a clobber list appearing after it got the
    // wrong (4-space, "not in asm") indent instead of asm's 2-space one.
    const input =
        \\pub fn syscall_fork() u64 {
        \\    return asm volatile (
        \\        \\ dec %%o1
        \\        \\ # Clear the child's %%o0
        \\        \\ and %%o1, %%o0, %%o0
        \\        : [ret] "={o0}" (-> u64),
        \\        : [number] "{g1}" (@intFromEnum(SYS.fork)),
        \\        : .{ .memory = true, .xcc = true, .o1 = true, .o2 = true, .o3 = true, .o4 = true, .o5 = true, .o7 = true });
        \\}
        \\
    ;
    const expected =
        \\pub fn syscall_fork() u64 {
        \\    return asm volatile (
        \\        \\ dec %%o1
        \\        \\ # Clear the child's %%o0
        \\        \\ and %%o1, %%o0, %%o0
        \\        : [ret] "={o0}" (-> u64),
        \\        : [number] "{g1}" (@intFromEnum(SYS.fork)),
        \\        : .{
        \\          .memory = true,
        \\          .xcc = true,
        \\          .o1 = true,
        \\          .o2 = true,
        \\          .o3 = true,
        \\          .o4 = true,
        \\          .o5 = true,
        \\          .o7 = true,
        \\        });
        \\}
        \\
    ;

    const formatted = try addTrailingCommas(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try addTrailingCommas(gpa, expected);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

/// Expands single-line lists with 3 or more items to one-per-line with trailing commas.
pub fn addTrailingCommas(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
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

        const indent_len = leadingSpaces(full_line);
        // `Ast/Render.zig` renders everything inside `asm (...)` /
        // `asm volatile (...)` with a 2-space indent step instead of the
        // usual 4 (its own `asm_indent_delta` vs. `indent_delta`).
        const indent_step: usize = if (line_idx < asm_line_flags.len and asm_line_flags[line_idx]) 2 else 4;
        try expandLine(
            gpa,
            &output,
            full_line,
            indent_len,
            indent_step,
        );
        if (line_start <= input.len) try output.append(gpa, '\n');
        line_idx += 1;
    }

    return output.toOwnedSlice(gpa);
}

fn expandLine(
    gpa: Allocator,
    output: *std.ArrayList(u8),
    line: []const u8,
    base_indent: usize,
    indent_step: usize,
) !void {
    // Zig multiline string literals use a double-backslash prefix on every
    // content line. Their content is not Zig code and must pass through verbatim.
    if (isMultilineStringLine(line)) {
        try output.appendSlice(gpa, line);
        return;
    }

    // A physical line with more than one top-level (bracket-depth-0)
    // comma-separated piece is either a `zig fmt`-bin-packed row of a
    // larger multi-line list (several short calls sharing one line) or a
    // single call sharing a row with unrelated sibling content. Either
    // way, this pass only ever sees one physical line at a time with no
    // notion of "row of a larger list" — expanding a construct found on
    // such a line would splice its output into text it doesn't understand
    // is part of the same row. Leave the whole line untouched instead.
    if (hasMultipleTopLevelSegments(line)) {
        try output.appendSlice(gpa, line);
        return;
    }

    var pos: usize = 0;
    var bracket_depth: usize = 0;

    while (pos < line.len) {
        const c = line[pos];

        if (c == '/' and pos + 1 < line.len and line[pos + 1] == '/') {
            try output.appendSlice(gpa, line[pos..]);
            return;
        }

        if (c == '\'' or c == '"') {
            const end = skipStringLiteral(line, pos);
            try output.appendSlice(gpa, line[pos..end]);
            pos = end;
            continue;
        }

        if (c == '[') bracket_depth += 1;
        if (c == ']' and bracket_depth > 0) bracket_depth -= 1;

        // A call/list nested directly inside an still-open `[...]`
        // index/slice is never expanded: `zig fmt` always breaks at the
        // bracket itself for that shape (which takes no trailing comma, a
        // different construct than this pass produces), so expanding the
        // inner call here would just be reformatted right back by a real
        // `zig fmt` pass.
        if ((c == '(' or c == '{') and bracket_depth == 0) {
            const close: u8 = if (c == '(') ')' else '}';
            if (findMatchingClose(
                line,
                pos,
                c,
                close,
            )) |close_pos| {
                const inner = line[pos + 1 .. close_pos];
                // Zig style: expand when there are 3+ items (2+ top-level commas).
                // Function decls use the same threshold as calls and aggregates —
                // a 2-parameter `fn` stays on one line.
                const commas = countTopLevelCommas(inner);

                if (commas >= 2 and !hasTrailingComma(inner)) {
                    const items = splitTopLevel(gpa, inner) catch return error.OutOfMemory;
                    defer gpa.free(items);

                    const item_indent = base_indent + indent_step;
                    try output.append(gpa, c);
                    try output.append(gpa, '\n');

                    for (items) |item| {
                        const trimmed = mem.trimStart(
                            u8,
                            mem.trimEnd(
                                u8,
                                item,
                                " ",
                            ),
                            " ",
                        );
                        try appendSpaces(
                            gpa,
                            output,
                            item_indent,
                        );
                        try expandLine(
                            gpa,
                            output,
                            trimmed,
                            item_indent,
                            indent_step,
                        );
                        try output.append(gpa, ',');
                        try output.append(gpa, '\n');
                    }

                    try appendSpaces(
                        gpa,
                        output,
                        base_indent,
                    );
                    try output.append(gpa, close);
                    pos = close_pos + 1;
                    continue;
                }
            }
        }

        try output.append(gpa, c);
        pos += 1;
    }
}

/// Reports whether `line` contains more than one non-empty, comma-separated
/// piece at bracket depth 0 (i.e. outside all `(`/`{`/`[` nesting). A line
/// with exactly one such piece is a single self-contained statement/item —
/// safe to expand. A line with more than one is a shared row: either a
/// `zig fmt`-bin-packed group of items from a larger multi-line list, or a
/// call sitting alongside unrelated sibling content on the same line.
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
                    if (mem.trim(
                        u8,
                        line[seg_start..i],
                        " \t",
                    ).len > 0) non_empty_segments += 1;
                    seg_start = i + 1;
                    if (non_empty_segments > 1) return true;
                }
            },
            else => {},
        }
    }
    if (mem.trim(
        u8,
        line[seg_start..],
        " \t",
    ).len > 0) non_empty_segments += 1;
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
        const line_end = mem.indexOfScalarPos(
            u8,
            input,
            line_start,
            '\n',
        ) orelse input.len;
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
    if (!mem.startsWith(
        u8,
        text[pos..],
        "asm",
    )) return null;
    if (pos > 0 and isIdentChar(text[pos - 1])) return null;
    var i = pos + 3;
    if (i < text.len and isIdentChar(text[i])) return null;

    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;

    if (mem.startsWith(
        u8,
        text[i..],
        "volatile",
    )) {
        const after = i + "volatile".len;
        if (after < text.len and isIdentChar(text[after])) return null;
        i = after;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    }

    if (i < text.len and text[i] == '(') return i;
    return null;
}

fn isIdentChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}

fn isMultilineStringLine(line: []const u8) bool {
    const trimmed = mem.trimStart(
        u8,
        line,
        " \t",
    );
    return mem.startsWith(
        u8,
        trimmed,
        "\\\\",
    );
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

fn countTopLevelCommas(inner: []const u8) usize {
    var count: usize = 0;
    var depth_paren: usize = 0;
    var depth_brace: usize = 0;
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
                if (depth_paren == 0 and depth_brace == 0) count += 1;
            },
            else => {},
        }
    }
    return count;
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
