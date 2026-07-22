//! [Go's rationale on respecting author's source blank newlines](https://github.com/golang/go/issues/22337#issuecomment-337943177).

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const format_test_assertions = @import("format_test_assertions.zig");

test "enforces logical blank lines" {
    const gpa = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\const mem = std.mem;
        \\fn example(gpa: std.mem.Allocator) void {
        \\    const source_code = "test";
        \\    var tree = std.zig.Ast.parse(gpa, source_code, .zig) catch return;
        \\    defer tree.deinit(gpa);
        \\    if (tree.errors.len != 0) {
        \\        std.debug.print("errors", .{});
        \\        return;
        \\    }
        \\    const rendered = tree.renderAlloc(gpa) catch return;
        \\    defer gpa.free(rendered);
        \\
        \\    if (rendered.len == 0) {
        \\        return;
        \\    }
        \\    std.debug.print("{s}", .{rendered});
        \\}
        \\
        \\fn dense(x: i32) void {
        \\    if (x > 0) {
        \\        doSomething();
        \\    }
        \\    const y = 2;
        \\    _ = y;
        \\    return;
        \\}
        \\
        \\fn already_spaced() void {
        \\    const a = 1;
        \\
        \\    const b = 2;
        \\    _ = a;
        \\    _ = b;
        \\}
        \\
        \\fn double_blanks() void {
        \\    const a = 1;
        \\
        \\
        \\    const b = 2;
        \\    _ = a;
        \\    _ = b;
        \\}
        \\
        \\fn nested(cond: bool) void {
        \\    if (cond) {
        \\
        \\        doSomething();
        \\
        \\    }
        \\    doB();
        \\}
        \\
        \\fn only_return() void {
        \\    return;
        \\}
        \\
        \\fn blank_before_return(x: i32) i32 {
        \\    const doubled = x * 2;
        \\    return doubled;
        \\}
        \\
        \\fn glued_defer(gpa: std.mem.Allocator) !void {
        \\    var list: std.ArrayList(u8) = .empty;
        \\
        \\    defer list.deinit(gpa);
        \\    try list.append(gpa, 1);
        \\}
        \\
        \\fn defer_group(gpa: std.mem.Allocator) !void {
        \\    var a: std.ArrayList(u8) = .empty;
        \\    defer a.deinit(gpa);
        \\    var b: std.ArrayList(u8) = .empty;
        \\    defer b.deinit(gpa);
        \\    errdefer b.deinit(gpa);
        \\    try a.append(gpa, 1);
        \\    _ = mem;
        \\}
        \\
        \\fn doSomething() void {}
        \\fn doB() void {}
        \\
    ;
    const expected =
        \\const std = @import("std");
        \\const mem = std.mem;
        \\
        \\fn example(gpa: std.mem.Allocator) void {
        \\    const source_code = "test";
        \\    var tree = std.zig.Ast.parse(gpa, source_code, .zig) catch return;
        \\    defer tree.deinit(gpa);
        \\
        \\    if (tree.errors.len != 0) {
        \\        std.debug.print("errors", .{});
        \\
        \\        return;
        \\    }
        \\
        \\    const rendered = tree.renderAlloc(gpa) catch return;
        \\    defer gpa.free(rendered);
        \\
        \\    if (rendered.len == 0) {
        \\        return;
        \\    }
        \\
        \\    std.debug.print("{s}", .{rendered});
        \\}
        \\
        \\fn dense(x: i32) void {
        \\    if (x > 0) {
        \\        doSomething();
        \\    }
        \\
        \\    const y = 2;
        \\    _ = y;
        \\
        \\    return;
        \\}
        \\
        \\fn already_spaced() void {
        \\    const a = 1;
        \\
        \\    const b = 2;
        \\    _ = a;
        \\    _ = b;
        \\}
        \\
        \\fn double_blanks() void {
        \\    const a = 1;
        \\
        \\    const b = 2;
        \\    _ = a;
        \\    _ = b;
        \\}
        \\
        \\fn nested(cond: bool) void {
        \\    if (cond) {
        \\        doSomething();
        \\    }
        \\
        \\    doB();
        \\}
        \\
        \\fn only_return() void {
        \\    return;
        \\}
        \\
        \\fn blank_before_return(x: i32) i32 {
        \\    const doubled = x * 2;
        \\
        \\    return doubled;
        \\}
        \\
        \\fn glued_defer(gpa: std.mem.Allocator) !void {
        \\    var list: std.ArrayList(u8) = .empty;
        \\    defer list.deinit(gpa);
        \\
        \\    try list.append(gpa, 1);
        \\}
        \\
        \\fn defer_group(gpa: std.mem.Allocator) !void {
        \\    var a: std.ArrayList(u8) = .empty;
        \\    defer a.deinit(gpa);
        \\
        \\    var b: std.ArrayList(u8) = .empty;
        \\    defer b.deinit(gpa);
        \\    errdefer b.deinit(gpa);
        \\
        \\    try a.append(gpa, 1);
        \\    _ = mem;
        \\}
        \\
        \\fn doSomething() void {}
        \\fn doB() void {}
        \\
    ;

    const formatted = try enforceLogicalBlankLines(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try enforceLogicalBlankLines(gpa, expected);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

/// Enforces logical blank line separation (vertical whitespace discipline).
///
/// Zig's AST renderer collapses consecutive blank lines to one, so this pass
/// never emits two blank lines in a row. Internal-vs-public import grouping is
/// owned by `sort_imports`; this pass only ensures a blank line between the
/// trailing import-related decls and the first non-import declaration.
///
/// Rules applied:
/// 1. One blank line after a closing `}` before the next statement
///    (unless followed by `}`, `else`, `catch`, or `)` continuation).
/// 2. One blank line before `return`/`continue`/`break`, unless it is the
///    first statement in its block (covers the sole-statement case).
/// 3. One blank line after `return`/`continue`/`break` when more statements
///    follow in the same block.
/// 4. `defer`/`errdefer` stay glued to their preceding initialization; a
///    blank line follows a defer group before the next non-defer statement.
/// 5. One blank line between the last import-related declaration and the
///    first non-import declaration.
/// 6. No blank line immediately after `{`.
/// 7. No blank line immediately before `}`.
/// 8. Never two consecutive blank lines.
pub fn enforceLogicalBlankLines(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);

    var line_start: usize = 0;
    while (line_start < input.len) {
        const line_end = mem.indexOfScalar(
            u8,
            input[line_start..],
            '\n',
        ) orelse input.len - line_start;
        try lines.append(gpa, input[line_start .. line_start + line_end]);
        line_start += line_end + 1;
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try output.ensureTotalCapacity(gpa, input.len + input.len / 8);

    var prev_was_blank = false;
    var prev_content: ?[]const u8 = null;

    for (lines.items, 0..) |line, i| {
        const trimmed = mem.trimStart(
            u8,
            mem.trimEnd(
                u8,
                line,
                " ",
            ),
            " ",
        );
        const is_blank = trimmed.len == 0;

        if (is_blank) {
            if (prev_was_blank) continue;
            if (prev_content) |pc| {
                if (mem.endsWith(
                    u8,
                    pc,
                    "{",
                )) continue;
            }
            if (i + 1 < lines.items.len) {
                const next_trimmed = mem.trimStart(
                    u8,
                    mem.trimEnd(
                        u8,
                        lines.items[i + 1],
                        " ",
                    ),
                    " ",
                );
                if (next_trimmed.len > 0 and next_trimmed[0] == '}') continue;
                // Keep defer/errdefer glued to the preceding initialization.
                if (isDeferLine(next_trimmed)) continue;
            }

            try output.appendSlice(gpa, line);
            try output.append(gpa, '\n');
            prev_was_blank = true;
            continue;
        }

        if (prev_content) |pc| {
            if (!prev_was_blank and shouldInsertBlank(pc, trimmed)) {
                try output.append(gpa, '\n');
            }
        }

        try output.appendSlice(gpa, line);
        try output.append(gpa, '\n');
        prev_was_blank = false;
        prev_content = trimmed;
    }

    return output.toOwnedSlice(gpa);
}

fn shouldInsertBlank(prev_trimmed: []const u8, next_trimmed: []const u8) bool {
    if (suppressesBlank(next_trimmed)) return false;
    if (isDeferLine(prev_trimmed) and isDeferLine(next_trimmed)) return false;
    if (isImportRelated(prev_trimmed) and isImportRelated(next_trimmed)) return false;

    if (needsBlankAfter(prev_trimmed)) return true;
    if (needsBlankBefore(next_trimmed, prev_trimmed)) return true;
    if (isImportRelated(prev_trimmed) and !isImportRelated(next_trimmed)) return true;

    return false;
}

fn needsBlankAfter(prev_trimmed: []const u8) bool {
    if (prev_trimmed.len == 0) return false;

    // Only "closing brace" lines — not one-liners like `fn foo() void {}`.
    if (mem.eql(
        u8,
        prev_trimmed,
        "}",
    ) or
        mem.eql(
            u8,
            prev_trimmed,
            "};",
        ) or
        mem.endsWith(
            u8,
            prev_trimmed,
            "};",
        ))
    {
        return true;
    }

    if (isFlowTerminator(prev_trimmed)) return true;
    if (isDeferLine(prev_trimmed)) return true;

    return false;
}

fn needsBlankBefore(next_trimmed: []const u8, prev_trimmed: []const u8) bool {
    if (!isFlowTerminator(next_trimmed)) return false;
    // First statement in a block (including the sole-statement case).
    if (mem.endsWith(
        u8,
        prev_trimmed,
        "{",
    )) return false;
    return true;
}

fn isFlowTerminator(trimmed: []const u8) bool {
    if (mem.startsWith(
        u8,
        trimmed,
        "return ",
    ) or mem.eql(
        u8,
        trimmed,
        "return;",
    )) return true;
    if (mem.startsWith(
        u8,
        trimmed,
        "continue ",
    ) or mem.eql(
        u8,
        trimmed,
        "continue;",
    )) return true;
    if (mem.eql(
        u8,
        trimmed,
        "break;",
    ) or mem.startsWith(
        u8,
        trimmed,
        "break ",
    )) return true;
    return false;
}

fn isDeferLine(trimmed: []const u8) bool {
    return mem.startsWith(
        u8,
        trimmed,
        "defer ",
    ) or
        mem.startsWith(
            u8,
            trimmed,
            "errdefer ",
        ) or
        mem.eql(
            u8,
            trimmed,
            "defer",
        ) or
        mem.eql(
            u8,
            trimmed,
            "errdefer",
        );
}

fn isImportRelated(trimmed: []const u8) bool {
    if (mem.indexOf(
        u8,
        trimmed,
        "@import",
    ) != null) return true;
    return isModuleAlias(trimmed);
}

/// `const Foo = bar.baz;` / `pub const Foo = bar.baz;` — aliases kept with imports.
fn isModuleAlias(trimmed: []const u8) bool {
    var line = trimmed;
    if (mem.startsWith(
        u8,
        line,
        "pub ",
    )) line = mem.trimStart(
        u8,
        line[4..],
        " ",
    );
    if (!mem.startsWith(
        u8,
        line,
        "const ",
    )) return false;

    const eq = mem.indexOf(
        u8,
        line,
        " = ",
    ) orelse return false;
    const rhs = line[eq + 3 ..];
    if (mem.indexOf(
        u8,
        rhs,
        "@",
    ) != null) return false;
    if (mem.indexOf(
        u8,
        rhs,
        "(",
    ) != null) return false;
    if (mem.indexOf(
        u8,
        rhs,
        "{",
    ) != null) return false;
    if (mem.indexOf(
        u8,
        rhs,
        ".",
    ) == null) return false;
    return true;
}

fn suppressesBlank(next_trimmed: []const u8) bool {
    if (next_trimmed.len == 0) return true;
    if (next_trimmed[0] == '}') return true;
    if (mem.startsWith(
        u8,
        next_trimmed,
        "} ",
    )) return true;
    if (mem.startsWith(
        u8,
        next_trimmed,
        "else",
    )) return true;
    if (mem.startsWith(
        u8,
        next_trimmed,
        "catch",
    )) return true;
    if (next_trimmed[0] == ')') return true;
    return false;
}
