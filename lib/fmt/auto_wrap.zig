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

/// Wraps over-long lines by expanding `(...)` / `{...}` lists. Caller owns the returned slice.
pub fn autoWrap(
    gpa: Allocator,
    input: []const u8,
    max_line_length: u32,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    try output.ensureTotalCapacity(gpa, input.len * 2);

    var line_start: usize = 0;
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
            var scratch: std.ArrayList(u8) = .empty;
            defer scratch.deinit(gpa);
            try expandOverlong(
                gpa,
                &scratch,
                full_line,
                indent_len,
                max_line_length,
            );
            try output.appendSlice(gpa, scratch.items);
        } else {
            try output.appendSlice(gpa, full_line);
        }

        if (line_start <= input.len) try output.append(gpa, '\n');
    }

    return output.toOwnedSlice(gpa);
}

fn expandOverlong(
    gpa: Allocator,
    output: *std.ArrayList(u8),
    line: []const u8,
    base_indent: usize,
    max_line_length: u32,
) !void {
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

                    const item_indent = base_indent + 4;
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

    // Nothing safe to break — leave the line as-is.
    try output.appendSlice(gpa, line);
}

/// Finds the leftmost `(...)` or `{...}` whose expansion would help: a real
/// call/parameter list (or `.{` literal) with non-empty, non-trailing-comma
/// content. Grouping and control-flow parens (`if (`, `while (`, `(a and
/// b)`, ...) are skipped — they can't take a trailing comma — but scanning
/// continues inside them since the real wrap target is often a call nested
/// in the condition.
fn findBestBreak(line: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < line.len) {
        const c = line[pos];

        if (c == '/' and pos + 1 < line.len and line[pos + 1] == '/') break;

        if (c == '\'' or c == '"') {
            pos = skipStringLiteral(line, pos);
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

            if (c == '(' and !isCallParen(line, pos)) {
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
    return switch (line[pos - 1]) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', ')', ']' => true,
        else => false,
    };
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
