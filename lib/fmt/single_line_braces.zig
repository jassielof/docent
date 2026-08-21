//! The single_line_braces namespace contains the logic to wrap single-line control-flow bodies in braces.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const format_test_assertions = @import("format_test_assertions.zig");

/// The enforceBraces function wraps single-line control-flow bodies in braces.
///
/// Converts patterns like `if (cond) return;` into multi-line braced blocks.
/// Handles `if`, `else`, `while`, `for`, and their chained variants.
/// Already-braced bodies and `else if` chains are left unchanged.
pub fn enforceBraces(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var all_lines: std.ArrayList([]const u8) = .empty;
    defer all_lines.deinit(gpa);
    {
        var pos: usize = 0;
        while (pos < input.len) {
            const end = mem.indexOfScalar(
                u8,
                input[pos..],
                '\n',
            ) orelse input.len - pos;
            try all_lines.append(gpa, input[pos .. pos + end]);
            pos += end + 1;
        }
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try output.ensureTotalCapacity(gpa, input.len + input.len / 4);

    var li: usize = 0;
    while (li < all_lines.items.len) {
        const full_line = all_lines.items[li];
        const indent_len = leadingSpaces(full_line);
        const trimmed = mem.trimEnd(
            u8,
            full_line,
            " ",
        );

        if (trimmed.len == 0) {
            try output.appendSlice(gpa, full_line);
            try output.append(gpa, '\n');
            li += 1;
            continue;
        }

        const content = full_line[indent_len..trimmed.len];
        const indent = full_line[0..indent_len];

        if (tryExpandSingleLine(
            gpa,
            &output,
            indent,
            content,
            all_lines.items,
            li,
        )) |expanded| {
            if (expanded) {
                try output.append(gpa, '\n');
                li += 1;
                continue;
            }
        } else |_| return error.OutOfMemory;

        const consumed = try tryExpandMultiLine(
            gpa,
            &output,
            all_lines.items,
            li,
        );
        if (consumed > 0) {
            li += consumed;
            continue;
        }

        try output.appendSlice(gpa, full_line);
        try output.append(gpa, '\n');
        li += 1;
    }

    return output.toOwnedSlice(gpa);
}

test "enforces braces for single-line control flow" {
    const gpa = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\
        \\fn doSomething() void {}
        \\fn foo() void {}
        \\fn bar() void {}
        \\fn alreadyBraced() void {}
        \\
        \\fn process(item: i32) void {
        \\    _ = item;
        \\}
        \\
        \\fn example() void {
        \\    const a = 5;
        \\    const b = 10;
        \\    const x = .{ .a = 1 };
        \\    const y = 30;
        \\    const iter: std.ArrayList(i32) = .empty;
        \\    const items = [_]i32{ 1, 2, 3 };
        \\
        \\    if (true) return;
        \\
        \\    if (a > b) doSomething();
        \\
        \\    if (x) foo() else bar();
        \\
        \\    while (iter.next()) |item| process(item);
        \\
        \\    for (items) |item| process(item);
        \\
        \\    if (true) {
        \\        alreadyBraced();
        \\    }
        \\
        \\    if (a) {
        \\        x;
        \\    } else if (b) {
        \\        y;
        \\    }
        \\
        \\    const conditional_value: usize = if (x > 4)
        \\        "greater"
        \\    else
        \\        "lesser";
        \\
        \\    _ = conditional_value;
        \\
        \\    const mode: i32 = if (a > b) 1 else 0;
        \\    _ = mode;
        \\
        \\    consume(
        \\        a,
        \\        if (a > b) 1 else 0,
        \\    );
        \\}
        \\
        \\fn consume(v: i32, w: i32) void {
        \\    _ = v;
        \\    _ = w;
        \\}
        \\
    ;
    const expected =
        \\const std = @import("std");
        \\
        \\fn doSomething() void {}
        \\fn foo() void {}
        \\fn bar() void {}
        \\fn alreadyBraced() void {}
        \\
        \\fn process(item: i32) void {
        \\    _ = item;
        \\}
        \\
        \\fn example() void {
        \\    const a = 5;
        \\    const b = 10;
        \\    const x = .{ .a = 1 };
        \\    const y = 30;
        \\    const iter: std.ArrayList(i32) = .empty;
        \\    const items = [_]i32{ 1, 2, 3 };
        \\
        \\    if (true) {
        \\        return;
        \\    }
        \\
        \\    if (a > b) {
        \\        doSomething();
        \\    }
        \\
        \\    if (x) {
        \\        foo();
        \\    } else {
        \\        bar();
        \\    }
        \\
        \\    while (iter.next()) |item| {
        \\        process(item);
        \\    }
        \\
        \\    for (items) |item| {
        \\        process(item);
        \\    }
        \\
        \\    if (true) {
        \\        alreadyBraced();
        \\    }
        \\
        \\    if (a) {
        \\        x;
        \\    } else if (b) {
        \\        y;
        \\    }
        \\
        \\    const conditional_value: usize = if (x > 4) {
        \\        "greater";
        \\    } else {
        \\        "lesser";
        \\    };
        \\
        \\    _ = conditional_value;
        \\
        \\    const mode: i32 = if (a > b) {
        \\        1;
        \\    } else {
        \\        0;
        \\    };
        \\    _ = mode;
        \\
        \\    consume(
        \\        a,
        \\        if (a > b) 1 else 0,
        \\    );
        \\}
        \\
        \\fn consume(v: i32, w: i32) void {
        \\    _ = v;
        \\    _ = w;
        \\}
        \\
    ;

    const formatted = try enforceBraces(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try enforceBraces(gpa, expected);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "leaves multi-capture for loops untouched (regression)" {
    // findBodyStart used to skip a `|...|` payload by scanning to the next
    // space rather than the closing `|`, so a multi-identifier capture list
    // (which contains its own internal spaces after each comma) got cut off
    // mid-list. The truncated remainder ("second| {") was then mistaken for
    // an unbraced single-statement body and wrapped, corrupting the syntax.
    const gpa = std.testing.allocator;

    const input =
        \\fn f(versions: []const u32) void {
        \\    for (versions[0 .. versions.len - 1], versions[1..versions.len]) |first, second| {
        \\        _ = first;
        \\        _ = second;
        \\    }
        \\}
        \\
    ;

    const formatted = try enforceBraces(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

test "still braces an unbraced multi-capture for loop body (regression)" {
    const gpa = std.testing.allocator;

    const input =
        \\fn f(a: []const u32, b: []const u32) void {
        \\    for (a, b) |first, second| use(first, second);
        \\}
        \\
    ;
    const expected =
        \\fn f(a: []const u32, b: []const u32) void {
        \\    for (a, b) |first, second| {
        \\        use(first, second);
        \\    }
        \\}
        \\
    ;

    const formatted = try enforceBraces(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

test "leaves while loops with a continue expression untouched (regression)" {
    // findBodyStart didn't recognize the `: (continue_expr)` clause that can
    // follow a while loop's condition, so it mistook `(continue_expr)` for
    // the loop body and left the real, braced body dangling as unparseable
    // trailing text.
    const gpa = std.testing.allocator;

    const input =
        \\fn f(limit: u32) void {
        \\    var i: u32 = 0;
        \\    while (i < limit) : (i += 1) {
        \\        use(i);
        \\    }
        \\}
        \\
    ;

    const formatted = try enforceBraces(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

test "leaves a captured while loop with a continue expression untouched (regression)" {
    const gpa = std.testing.allocator;

    const input =
        \\fn f(it: *Iterator) void {
        \\    while (it.next()) |item| : (it.advance()) {
        \\        use(item);
        \\    }
        \\}
        \\
    ;

    const formatted = try enforceBraces(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

test "still braces an unbraced while loop with a continue expression (regression)" {
    const gpa = std.testing.allocator;

    const input =
        \\fn f(limit: u32) void {
        \\    var i: u32 = 0;
        \\    while (i < limit) : (i += 1) use(i);
        \\}
        \\
    ;
    const expected =
        \\fn f(limit: u32) void {
        \\    var i: u32 = 0;
        \\    while (i < limit) : (i += 1) {
        \\        use(i);
        \\    }
        \\}
        \\
    ;

    const formatted = try enforceBraces(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

test "leaves an already-braced error-payload else untouched (regression)" {
    // `} else |_| {}` carries a payload capture before its braced body. The
    // old code treated everything after `} else ` as the body, so it saw
    // `|_| {}` (which doesn't start with `{`) and tried to wrap it, tearing
    // the capture away from its body.
    const gpa = std.testing.allocator;

    const input =
        \\fn f() !void {
        \\    doThing() catch |_| {};
        \\    if (cond) {
        \\        doA();
        \\    } else |err| {
        \\        handle(err);
        \\    }
        \\}
        \\
    ;

    const formatted = try enforceBraces(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

test "still braces an unbraced error-payload else body (regression)" {
    const gpa = std.testing.allocator;

    const input =
        \\fn f(cond: bool) void {
        \\    if (cond) {
        \\        doA();
        \\    } else |err| handle(err);
        \\}
        \\
    ;
    const expected =
        \\fn f(cond: bool) void {
        \\    if (cond) {
        \\        doA();
        \\    } else |err| {
        \\        handle(err);
        \\    }
        \\}
        \\
    ;

    const formatted = try enforceBraces(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

test "leaves a switch-expression while body untouched (regression)" {
    // `while (cond) switch (x) { ... };` is an unbraced while body whose
    // single statement is itself a multi-line brace-delimited switch
    // expression. findBodyStart correctly lands right after `switch (x) `,
    // but the old `body[0] == '{'` guard only checked the body's very first
    // character ('s' of "switch"), not whether the body opens a brace it
    // doesn't close on the same line — so this got wrapped as if `switch
    // (x) {` were a complete single-line statement, nesting a spurious `{`
    // one level too deep and closing it before the switch's real prongs.
    const gpa = std.testing.allocator;
    const input =
        \\fn genBoolExpr(base: i32) void {
        \\    var node = base;
        \\    while (true) switch (node) {
        \\        1 => node = 2,
        \\        else => break,
        \\    };
        \\    _ = node;
        \\}
        \\
    ;

    const formatted = try enforceBraces(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

test "leaves an unbraced else body that is a multi-line call untouched (regression)" {
    // `} else panic(\n    args,\n);` has a body that opens a paren it
    // doesn't close on this line. The old code saw a non-'{' first
    // character and wrapped it as `} else {\n    panic(\n}`, splitting the
    // call's argument list off into orphaned, unparseable lines.
    const gpa = std.testing.allocator;
    const input =
        \\fn f(rhs: u32) void {
        \\    if (rhs == 0) {
        \\        doSomething();
        \\    } else panic(
        \\        @returnAddress(),
        \\        "division by zero",
        \\        .{},
        \\    );
        \\}
        \\
    ;

    const formatted = try enforceBraces(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

test "leaves an else-if chain with a multi-line first branch untouched (regression)" {
    // `const x = if (cond) |c| BODY else if (cond2) |c| BODY2 else unreachable;`
    // spanning multiple lines is not a plain two-branch if/else:
    // tryExpandMultiLine used to treat line `start + 2` ("else if (...)") as
    // if it always meant the whole construct is a simple if/else, dropping
    // the rest of the chain (`else if (...) ... else unreachable;`) on the
    // floor as dangling, unparseable text after the wrapper it emitted.
    const gpa = std.testing.allocator;
    const input =
        \\fn f(a: bool, b: bool) type {
        \\    const type_node = if (a) |full|
        \\        full.a
        \\    else if (b) |full|
        \\        full.b
        \\    else
        \\        unreachable;
        \\    _ = type_node;
        \\}
        \\
    ;

    const formatted = try enforceBraces(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

test "leaves an else tail of an expression-valued if untouched (regression)" {
    // `const token = if (cond) |f| b: { ... break :b value; } else tail;`
    // is an expression-valued if: the else branch is a bare tail
    // expression, and the `;` after it terminates the whole assignment, not
    // the branch. The old code saw a brace/paren-balanced, non-block else
    // body and wrapped it as `} else {\n    tail\n}`, which swallows that
    // `;` as the new block's own terminator and leaves the outer
    // `const token = if (...) ... else {...}` without one, producing
    // `error: expected ';' after statement`. It also turns the branch from
    // an expression into a void statement, changing the if's type. Adapted
    // from a real bug found in std.zon.parse's failUnexpected.
    const gpa = std.testing.allocator;
    const input =
        \\fn f(field: ?usize) usize {
        \\    const token = if (field) |x| b: {
        \\        break :b x - 2;
        \\    } else other(node);
        \\    return token;
        \\}
        \\
    ;

    const formatted = try enforceBraces(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

test "still braces an unbraced else tail of a plain statement-if (regression)" {
    // A plain statement-if's opening line isn't an assignment, so its
    // unbraced else tail should still be wrapped as before; only
    // expression-valued ifs are exempted.
    const gpa = std.testing.allocator;
    const input =
        \\fn f(cond: bool) void {
        \\    if (cond) {
        \\        doA();
        \\    } else doB();
        \\}
        \\
    ;
    const expected =
        \\fn f(cond: bool) void {
        \\    if (cond) {
        \\        doA();
        \\    } else {
        \\        doB();
        \\    }
        \\}
        \\
    ;

    const formatted = try enforceBraces(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);
}

const keywords = [_][]const u8{
    "if ",
    "while ",
    "for ",
};

fn tryExpandSingleLine(
    gpa: Allocator,
    output: *std.ArrayList(u8),
    indent: []const u8,
    content: []const u8,
    all_lines: []const []const u8,
    li: usize,
) !bool {
    if (content.len == 0) return false;
    if (content[content.len - 1] == ',') return false;

    if (mem.startsWith(
        u8,
        content,
        "} else ",
    )) {
        const after_else = content[7..];
        if (after_else.len == 0) return false;

        // A `}` that closes the *value* of an assignment (`const x = if
        // (cond) label: { ... } else tail;`) needs different handling than
        // one that closes a plain statement-if: the trailing `;` here
        // terminates the whole assignment, not this branch, and wrapping
        // `tail` in a block would change it from an expression to a void
        // statement, breaking both the semicolon placement and the type of
        // the if-expression. There's no such signal on this line alone, so
        // walk back to the line that opens the brace this one closes and
        // check whether it reads like an assignment.
        if (opensAssignedValue(all_lines, li)) return false;

        // An error-union `else` branch may carry a payload capture
        // (`} else |err| ...`) before its body; skip past it so the `{`
        // check and the wrap below apply to the actual body, not the
        // capture. Without this, an already-braced payload branch like
        // `} else |_| {}` gets its body torn away from the capture and
        // wrapped on its own, stranding `|_|` as an orphaned statement.
        var body_offset: usize = 0;
        if (after_else[0] == '|') {
            body_offset = 1;
            while (body_offset < after_else.len and after_else[body_offset] != '|') : (body_offset += 1) {}
            if (body_offset < after_else.len) body_offset += 1;
            while (body_offset < after_else.len and after_else[body_offset] == ' ') : (body_offset += 1) {}
        }

        const header = after_else[0..body_offset];
        const body = after_else[body_offset..];
        if (body.len == 0 or body[0] == '{' or hasUnbalancedOpenDelimiter(body)) return false;

        for (keywords) |kw| {
            if (mem.startsWith(u8, body, kw)) return false;
        }

        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, "} else ");
        try output.appendSlice(gpa, header);
        try output.append(gpa, '{');
        try output.append(gpa, '\n');
        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, "    ");
        try output.appendSlice(gpa, body);
        try output.append(gpa, '\n');
        try output.appendSlice(gpa, indent);
        try output.append(gpa, '}');
        return true;
    }

    for (keywords) |kw| {
        if (!mem.startsWith(
            u8,
            content,
            kw,
        )) continue;

        const body_start = findBodyStart(content) orelse continue;
        const body = content[body_start..];
        if (body.len == 0 or body[0] == '{' or hasUnbalancedOpenDelimiter(body)) continue;

        if (mem.startsWith(
            u8,
            content,
            "if ",
        )) {
            if (findInlineElse(body)) |else_offset| {
                const if_body = body[0..else_offset];
                const after_else = else_offset + 5;
                const else_body_start = if (after_else < body.len and body[after_else] == ' ') after_else + 1 else after_else;
                const else_body = body[else_body_start..];
                const needs_semi = if_body.len > 0 and if_body[if_body.len - 1] != ';';

                try output.appendSlice(gpa, indent);
                try output.appendSlice(gpa, content[0..body_start]);
                try output.append(gpa, '{');
                try output.append(gpa, '\n');
                try output.appendSlice(gpa, indent);
                try output.appendSlice(gpa, "    ");
                try output.appendSlice(gpa, if_body);
                if (needs_semi) try output.append(gpa, ';');
                try output.append(gpa, '\n');
                try output.appendSlice(gpa, indent);
                try output.appendSlice(gpa, "} else {");
                try output.append(gpa, '\n');
                try output.appendSlice(gpa, indent);
                try output.appendSlice(gpa, "    ");
                try output.appendSlice(gpa, else_body);
                try output.append(gpa, '\n');
                try output.appendSlice(gpa, indent);
                try output.append(gpa, '}');
                return true;
            }
        }

        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, content[0..body_start]);
        try output.append(gpa, '{');
        try output.append(gpa, '\n');
        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, "    ");
        try output.appendSlice(gpa, body);
        try output.append(gpa, '\n');
        try output.appendSlice(gpa, indent);
        try output.append(gpa, '}');
        return true;
    }

    if (mem.indexOf(
        u8,
        content,
        " = if (",
    )) |eq_if_pos| {
        const if_start = eq_if_pos + 3;
        const after_if = content[if_start..];
        const body_start = findBodyStart(after_if) orelse return false;
        const body = after_if[body_start..];
        if (body.len == 0 or body[0] == '{' or hasUnbalancedOpenDelimiter(body)) return false;

        if (findInlineElse(body)) |else_offset| {
            const if_body = body[0..else_offset];
            const after_else_off = else_offset + 5;
            const else_body_start = if (after_else_off < body.len and body[after_else_off] == ' ') after_else_off + 1 else after_else_off;
            const else_body_raw = body[else_body_start..];
            const else_body = if (mem.endsWith(
                u8,
                else_body_raw,
                ";",
            ))
                else_body_raw[0 .. else_body_raw.len - 1]
            else
                else_body_raw;
            const if_needs_semi = if_body.len > 0 and if_body[if_body.len - 1] != ';';

            try output.appendSlice(gpa, indent);
            try output.appendSlice(gpa, content[0 .. if_start + body_start]);
            try output.appendSlice(gpa, "{\n");
            try output.appendSlice(gpa, indent);
            try output.appendSlice(gpa, "    ");
            try output.appendSlice(gpa, if_body);
            if (if_needs_semi) try output.append(gpa, ';');
            try output.appendSlice(gpa, "\n");
            try output.appendSlice(gpa, indent);
            try output.appendSlice(gpa, "} else {\n");
            try output.appendSlice(gpa, indent);
            try output.appendSlice(gpa, "    ");
            try output.appendSlice(gpa, else_body);
            try output.appendSlice(gpa, ";\n");
            try output.appendSlice(gpa, indent);
            try output.appendSlice(gpa, "};");
            return true;
        }
    }

    return false;
}

/// Walks backward from `all_lines[li]` (which must start with `}`) to the
/// line that opens the brace it closes, and reports whether that line reads
/// like the start of an assignment or `return` (`const x = if (cond)
/// label: {`, `return if (cond) label: {`). Such an `if` is used for its
/// *value*: its `else` branch must itself be a value-producing expression,
/// not a block, and the statement's terminating `;` lives at the very end
/// of the whole `if`/`else`, not inside either branch. A plain
/// statement-`if`'s opening line has neither signal.
fn opensAssignedValue(all_lines: []const []const u8, li: usize) bool {
    var depth: isize = 1; // accounts for the '}' that starts all_lines[li]
    var line_idx = li;
    while (line_idx > 0) {
        line_idx -= 1;
        const line = all_lines[line_idx];

        var i = line.len;
        while (i > 0) {
            i -= 1;
            if (line[i] == '}') {
                depth += 1;
            } else if (line[i] == '{') {
                depth -= 1;
                if (depth == 0) {
                    const trimmed = mem.trim(
                        u8,
                        line,
                        " \t",
                    );
                    return mem.indexOf(u8, trimmed, " = if (") != null or
                        mem.startsWith(u8, trimmed, "return if (");
                }
            }
        }
    }
    return false;
}

/// Reports whether `body` contains a brace or paren opened on this line but
/// not closed on the same line — i.e. `body` is only a fragment of a
/// multi-line construct (a multi-line function call, a switch expression,
/// etc.), not a complete single-line statement safe to wrap on its own.
fn hasUnbalancedOpenDelimiter(body: []const u8) bool {
    var brace_depth: isize = 0;
    var paren_depth: isize = 0;
    for (body) |c| {
        switch (c) {
            '{' => brace_depth += 1,
            '}' => brace_depth -= 1,
            '(' => paren_depth += 1,
            ')' => paren_depth -= 1,
            else => {},
        }
    }
    return brace_depth > 0 or paren_depth > 0;
}

/// Handles multi-line unbraced control flow, e.g.:
/// ```
///   const x = if (CONDITION)
///       BODY
///   else
///       OTHER_BODY;
/// ```
fn tryExpandMultiLine(
    gpa: Allocator,
    output: *std.ArrayList(u8),
    lines: []const []const u8,
    start: usize,
) !usize {
    const first = lines[start];
    const indent_len = leadingSpaces(first);
    const trimmed = mem.trimEnd(
        u8,
        first,
        " ",
    );
    const content = first[indent_len..trimmed.len];
    const indent = first[0..indent_len];

    const has_assign = mem.indexOf(
        u8,
        content,
        " = ",
    ) != null;
    if (!has_assign) return 0;

    const if_pos = mem.indexOf(
        u8,
        content,
        "if (",
    ) orelse return 0;
    const after_if = content[if_pos..];

    const body_start_opt = findBodyStart(after_if);
    if (body_start_opt) |bs| {
        if (bs < after_if.len) return 0;
    }
    const header_end = if_pos + (body_start_opt orelse after_if.len);

    if (start + 1 >= lines.len) return 0;

    const body_line_raw = lines[start + 1];
    const body_trimmed = mem.trimStart(
        u8,
        mem.trimEnd(
            u8,
            body_line_raw,
            " ",
        ),
        " ",
    );
    if (body_trimmed.len == 0 or body_trimmed[0] == '{') return 0;

    var consumed: usize = 2;

    var else_line_raw: ?[]const u8 = null;
    var else_body_raw: ?[]const u8 = null;

    if (start + 2 < lines.len) {
        const candidate = mem.trimStart(
            u8,
            mem.trimEnd(
                u8,
                lines[start + 2],
                " ",
            ),
            " ",
        );
        if (mem.eql(
            u8,
            candidate,
            "else",
        )) {
            else_line_raw = lines[start + 2];
            consumed = 3;
            if (start + 3 < lines.len) {
                else_body_raw = lines[start + 3];
                consumed = 4;
            }
        }
    }

    // Anything other than a plain two-branch `if`/`else` isn't safe to
    // handle here — most notably an `else if` chain, where `start + 2` is
    // neither a bare "else" line nor the tail of a self-terminated
    // statement. Treating the first branch as the whole construct (as this
    // function used to) drops the rest of the chain on the floor, leaving
    // it as dangling, unparseable text after the wrapper this function
    // emits. If there's no recognized `else` and the body isn't already a
    // complete, semicolon-terminated statement, bail and leave every line
    // untouched instead of guessing.
    if (else_line_raw == null and (body_trimmed.len == 0 or body_trimmed[body_trimmed.len - 1] != ';')) {
        return 0;
    }

    try output.appendSlice(gpa, indent);
    try output.appendSlice(gpa, content[0..header_end]);
    try output.appendSlice(gpa, " {\n");

    try output.appendSlice(gpa, indent);
    try output.appendSlice(gpa, "    ");
    const body_needs_semi = body_trimmed.len > 0 and body_trimmed[body_trimmed.len - 1] != ';' and else_line_raw != null;
    try output.appendSlice(gpa, body_trimmed);
    if (body_needs_semi) try output.append(gpa, ';');
    try output.append(gpa, '\n');

    if (else_line_raw != null) {
        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, "} else {\n");

        if (else_body_raw) |eb| {
            const eb_trimmed = mem.trimStart(
                u8,
                mem.trimEnd(
                    u8,
                    eb,
                    " ",
                ),
                " ",
            );
            try output.appendSlice(gpa, indent);
            try output.appendSlice(gpa, "    ");
            try output.appendSlice(gpa, eb_trimmed);
            try output.append(gpa, '\n');
        }

        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, "};\n");
    } else {
        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, "}\n");
    }

    return consumed;
}

/// Finds where the body starts after a control-flow condition.
/// Skips past balanced parentheses to find the body portion.
fn findBodyStart(content: []const u8) ?usize {
    var i: usize = 0;
    while (i < content.len and content[i] != '(') : (i += 1) {}
    if (i >= content.len) return null;

    i = skipBalancedParens(content, i) orelse return null;

    while (i < content.len and content[i] == ' ') : (i += 1) {}

    if (i < content.len and content[i] == '|') {
        i += 1;
        while (i < content.len and content[i] != '|') : (i += 1) {}
        if (i < content.len) i += 1;
        while (i < content.len and content[i] == ' ') : (i += 1) {}
    }

    // An optional `: (continue_expr)` clause follows a while loop's capture
    // (or condition, if uncaptured); skip past it too so it isn't mistaken
    // for the loop body.
    if (i < content.len and content[i] == ':') {
        i += 1;
        while (i < content.len and content[i] == ' ') : (i += 1) {}
        if (i < content.len and content[i] == '(') {
            i = skipBalancedParens(content, i) orelse return null;
            while (i < content.len and content[i] == ' ') : (i += 1) {}
        }
    }

    if (i >= content.len) return null;
    return i;
}

/// Advances from an opening `(` at `open` to just past its matching `)`.
fn skipBalancedParens(content: []const u8, open: usize) ?usize {
    var i = open;
    var depth: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '(') {
            depth += 1;
        } else if (content[i] == ')') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

/// Finds ` else ` in a body string, skipping over balanced parentheses.
fn findInlineElse(body: []const u8) ?usize {
    var i: usize = 0;
    var depth: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '(') {
            depth += 1;
        } else if (body[i] == ')') {
            if (depth > 0) depth -= 1;
        } else if (depth == 0 and i + 5 <= body.len) {
            if (mem.eql(
                u8,
                body[i .. i + 5],
                " else",
            )) {
                if (i + 5 == body.len or body[i + 5] == ' ') return i;
            }
        }
    }
    return null;
}

fn leadingSpaces(line: []const u8) usize {
    for (line, 0..) |c, i| {
        if (c != ' ') return i;
    }
    return line.len;
}
