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

/// Expands single-line lists with 3 or more items to one-per-line with trailing commas.
pub fn addTrailingCommas(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    try output.ensureTotalCapacity(gpa, input.len * 2);

    var line_start: usize = 0;
    while (line_start < input.len) {
        const line_end = mem.indexOfScalar(u8, input[line_start..], '\n') orelse input.len - line_start;
        const full_line = input[line_start .. line_start + line_end];
        line_start += line_end + 1;

        const indent_len = leadingSpaces(full_line);
        try expandLine(gpa, &output, full_line, indent_len);
        if (line_start <= input.len) try output.append(gpa, '\n');
    }

    return output.toOwnedSlice(gpa);
}

fn expandLine(gpa: Allocator, output: *std.ArrayList(u8), line: []const u8, base_indent: usize) !void {
    var pos: usize = 0;

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

        if (c == '(' or c == '{') {
            const close: u8 = if (c == '(') ')' else '}';
            if (findMatchingClose(line, pos, c, close)) |close_pos| {
                const inner = line[pos + 1 .. close_pos];
                // Zig style: expand when there are 3+ items (2+ top-level commas).
                // Function decls use the same threshold as calls and aggregates —
                // a 2-parameter `fn` stays on one line.
                const commas = countTopLevelCommas(inner);

                if (commas >= 2 and !hasTrailingComma(inner)) {
                    const items = splitTopLevel(gpa, inner) catch return error.OutOfMemory;
                    defer gpa.free(items);

                    const item_indent = base_indent + 4;
                    try output.append(gpa, c);
                    try output.append(gpa, '\n');

                    for (items) |item| {
                        const trimmed = mem.trimStart(u8, mem.trimEnd(u8, item, " "), " ");
                        try appendSpaces(gpa, output, item_indent);
                        try expandLine(gpa, output, trimmed, item_indent);
                        try output.append(gpa, ',');
                        try output.append(gpa, '\n');
                    }

                    try appendSpaces(gpa, output, base_indent);
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

fn appendSpaces(gpa: Allocator, output: *std.ArrayList(u8), count: usize) !void {
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

fn findMatchingClose(line: []const u8, start: usize, open: u8, close: u8) ?usize {
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
    const trimmed = mem.trimEnd(u8, inner, " ");
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
