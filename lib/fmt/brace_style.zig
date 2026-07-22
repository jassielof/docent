//! The brace_style namespace contains the logic to reformat brace styles.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const format_test_assertions = @import("format_test_assertions.zig");

/// Target brace placement style. Zig's own AST renderer (`tree.render()`)
/// always emits K&R, so every style here describes a post-processing
/// transform *from* that canonical output -- `.k_r` is the identity case,
/// needing no rewrite. Adding a new style (e.g. Whitesmiths, Stroustrup)
/// means adding a variant here and a branch in `convert`; callers never
/// hardcode a specific style by name (see `Formatter.zig`'s `applyPostProcessing`,
/// which just calls `convert(gpa, current, config.brace_style)`).
pub const Style = enum {
    k_r,
    allman,

    /// Config / diagnostic label for this style.
    pub fn label(self: Style) []const u8 {
        return switch (self) {
            .k_r => "K&R",
            .allman => "Allman",
        };
    }

    /// Parses TOML / schema spellings (`k_r`, `k&r`, `allman`).
    pub fn fromConfigString(text: []const u8) ?Style {
        if (mem.eql(u8, text, "k_r") or mem.eql(u8, text, "k&r")) return .k_r;
        if (mem.eql(u8, text, "allman")) return .allman;
        return null;
    }
};

/// Converts Zig's rendered (K&R) output to `style`. Caller owns the
/// returned slice.
pub fn convert(gpa: Allocator, input: []const u8, style: Style) Allocator.Error![]u8 {
    return switch (style) {
        .k_r => gpa.dupe(u8, input),
        .allman => convertToAllman(gpa, input),
    };
}

/// Converts K&R brace style to Allman style by post-processing rendered output.
///
/// Moves opening braces to their own line and separates `} else`/`} catch` clauses onto individual lines. Struct/tuple literals (`.{`) and empty blocks (`{}`) are left unchanged.
pub fn convertToAllman(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    try output.ensureTotalCapacity(gpa, input.len + input.len / 4);

    var line_start: usize = 0;
    while (line_start < input.len) {
        const line_end = mem.indexOfScalar(u8, input[line_start..], '\n') orelse input.len - line_start;
        const full_line = input[line_start .. line_start + line_end];
        line_start += line_end + 1;

        const trimmed = mem.trimEnd(u8, full_line, " ");
        if (trimmed.len == 0) {
            try output.appendSlice(gpa, full_line);
            if (line_start <= input.len) try output.append(gpa, '\n');
            continue;
        }

        const indent_len = leadingSpaces(full_line);
        const indent = full_line[0..indent_len];
        const content = full_line[indent_len..trimmed.len];

        if (tryHandleElseCatch(gpa, &output, indent, content) catch return error.OutOfMemory) {
            if (line_start <= input.len) try output.append(gpa, '\n');
            continue;
        }

        if (tryHandleTrailingBrace(gpa, &output, indent, content) catch return error.OutOfMemory) {
            if (line_start <= input.len) try output.append(gpa, '\n');
            continue;
        }

        try output.appendSlice(gpa, full_line);
        if (line_start <= input.len) try output.append(gpa, '\n');
    }

    return output.toOwnedSlice(gpa);
}

fn leadingSpaces(line: []const u8) usize {
    for (line, 0..) |c, i| {
        if (c != ' ') return i;
    }
    return line.len;
}

fn tryHandleElseCatch(gpa: Allocator, output: *std.ArrayList(u8), indent: []const u8, content: []const u8) !bool {
    if (content.len < 3 or content[0] != '}' or content[1] != ' ') return false;

    const rest = content[2..];
    const is_else = mem.startsWith(u8, rest, "else");
    const is_catch = mem.startsWith(u8, rest, "catch");
    if (!is_else and !is_catch) return false;

    try output.appendSlice(gpa, indent);
    try output.append(gpa, '}');
    try output.append(gpa, '\n');

    if (endsWithBlockBrace(rest)) {
        const rest_without_brace = mem.trimEnd(u8, rest[0 .. rest.len - 2], " ");
        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, rest_without_brace);
        try output.append(gpa, '\n');
        try output.appendSlice(gpa, indent);
        try output.append(gpa, '{');
    } else {
        try output.appendSlice(gpa, indent);
        try output.appendSlice(gpa, rest);
    }

    return true;
}

fn tryHandleTrailingBrace(gpa: Allocator, output: *std.ArrayList(u8), indent: []const u8, content: []const u8) !bool {
    if (!endsWithBlockBrace(content)) return false;

    const without_brace = mem.trimEnd(u8, content[0 .. content.len - 2], " ");
    try output.appendSlice(gpa, indent);
    try output.appendSlice(gpa, without_brace);
    try output.append(gpa, '\n');
    try output.appendSlice(gpa, indent);
    try output.append(gpa, '{');

    return true;
}

fn endsWithBlockBrace(content: []const u8) bool {
    if (content.len < 2) return false;
    if (!mem.endsWith(u8, content, " {")) return false;
    if (content.len >= 3 and content[content.len - 3] == '.') return false;
    return true;
}

test "converts braces to Allman style" {
    const gpa = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\
        \\fn main() void {
        \\    return;
        \\}
        \\
        \\fn example(cond: bool, a: bool, b: bool) void {
        \\    if (cond) {
        \\        std.debug.print("body", .{});
        \\    } else {
        \\        std.debug.print("other", .{});
        \\    }
        \\
        \\    if (a) {
        \\        std.debug.print("x", .{});
        \\    } else if (b) {
        \\        std.debug.print("y", .{});
        \\    } else {
        \\        std.debug.print("z", .{});
        \\    }
        \\
        \\    const val = doSomething() catch |err| {
        \\        _ = err;
        \\    };
        \\    _ = val;
        \\
        \\    const x = .{ .a = 1 };
        \\    _ = x;
        \\    if (cond) {}
        \\}
        \\
        \\fn doSomething() !void {}
        \\
    ;
    const expected =
        \\const std = @import("std");
        \\
        \\fn main() void
        \\{
        \\    return;
        \\}
        \\
        \\fn example(cond: bool, a: bool, b: bool) void
        \\{
        \\    if (cond)
        \\    {
        \\        std.debug.print("body", .{});
        \\    }
        \\    else
        \\    {
        \\        std.debug.print("other", .{});
        \\    }
        \\
        \\    if (a)
        \\    {
        \\        std.debug.print("x", .{});
        \\    }
        \\    else if (b)
        \\    {
        \\        std.debug.print("y", .{});
        \\    }
        \\    else
        \\    {
        \\        std.debug.print("z", .{});
        \\    }
        \\
        \\    const val = doSomething() catch |err|
        \\    {
        \\        _ = err;
        \\    };
        \\    _ = val;
        \\
        \\    const x = .{ .a = 1 };
        \\    _ = x;
        \\    if (cond) {}
        \\}
        \\
        \\fn doSomething() !void {}
        \\
    ;

    const formatted = try convertToAllman(gpa, input);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try convertToAllman(gpa, expected);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "dispatches brace style conversion" {
    const gpa = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\
        \\fn main() void {
        \\    return;
        \\}
        \\
        \\fn example(cond: bool, a: bool, b: bool) void {
        \\    if (cond) {
        \\        std.debug.print("body", .{});
        \\    } else {
        \\        std.debug.print("other", .{});
        \\    }
        \\
        \\    if (a) {
        \\        std.debug.print("x", .{});
        \\    } else if (b) {
        \\        std.debug.print("y", .{});
        \\    } else {
        \\        std.debug.print("z", .{});
        \\    }
        \\
        \\    const val = doSomething() catch |err| {
        \\        _ = err;
        \\    };
        \\    _ = val;
        \\
        \\    const x = .{ .a = 1 };
        \\    _ = x;
        \\    if (cond) {}
        \\}
        \\
        \\fn doSomething() !void {}
        \\
    ;
    const allman_expected =
        \\const std = @import("std");
        \\
        \\fn main() void
        \\{
        \\    return;
        \\}
        \\
        \\fn example(cond: bool, a: bool, b: bool) void
        \\{
        \\    if (cond)
        \\    {
        \\        std.debug.print("body", .{});
        \\    }
        \\    else
        \\    {
        \\        std.debug.print("other", .{});
        \\    }
        \\
        \\    if (a)
        \\    {
        \\        std.debug.print("x", .{});
        \\    }
        \\    else if (b)
        \\    {
        \\        std.debug.print("y", .{});
        \\    }
        \\    else
        \\    {
        \\        std.debug.print("z", .{});
        \\    }
        \\
        \\    const val = doSomething() catch |err|
        \\    {
        \\        _ = err;
        \\    };
        \\    _ = val;
        \\
        \\    const x = .{ .a = 1 };
        \\    _ = x;
        \\    if (cond) {}
        \\}
        \\
        \\fn doSomething() !void {}
        \\
    ;
    const k_r_expected =
        \\const std = @import("std");
        \\
        \\fn main() void {
        \\    return;
        \\}
        \\
        \\fn example(cond: bool, a: bool, b: bool) void {
        \\    if (cond) {
        \\        std.debug.print("body", .{});
        \\    } else {
        \\        std.debug.print("other", .{});
        \\    }
        \\
        \\    if (a) {
        \\        std.debug.print("x", .{});
        \\    } else if (b) {
        \\        std.debug.print("y", .{});
        \\    } else {
        \\        std.debug.print("z", .{});
        \\    }
        \\
        \\    const val = doSomething() catch |err| {
        \\        _ = err;
        \\    };
        \\    _ = val;
        \\
        \\    const x = .{ .a = 1 };
        \\    _ = x;
        \\    if (cond) {}
        \\}
        \\
        \\fn doSomething() !void {}
        \\
    ;

    const allman_formatted = try convert(gpa, input, .allman);
    defer gpa.free(allman_formatted);
    try std.testing.expectEqualStrings(allman_expected, allman_formatted);
    try format_test_assertions.expectValidZig(allman_formatted);

    const allman_formatted_expected = try convert(gpa, allman_expected, .allman);
    defer gpa.free(allman_formatted_expected);
    try format_test_assertions.expectIdempotent(allman_expected, allman_formatted_expected);

    const k_r_formatted = try convert(gpa, input, .k_r);
    defer gpa.free(k_r_formatted);
    try std.testing.expectEqualStrings(k_r_expected, k_r_formatted);
    try format_test_assertions.expectValidZig(k_r_formatted);

    const k_r_formatted_expected = try convert(gpa, k_r_expected, .k_r);
    defer gpa.free(k_r_formatted_expected);
    try format_test_assertions.expectIdempotent(k_r_expected, k_r_formatted_expected);
}
