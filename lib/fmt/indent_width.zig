//! The indent_width namespace contains the logic to re-indent source code to a different width or character.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const format_test_assertions = @import("format_test_assertions.zig");

test "reindents using two spaces" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/indent_width/input.zig");
    const expected = @embedFile("fixtures/indent_width/expected_spaces_2.zig");

    const formatted = try reindent(gpa, input, .space, 2);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try reindent(gpa, expected, .space, 2);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

test "reindents using tabs" {
    const gpa = std.testing.allocator;
    const input = @embedFile("fixtures/indent_width/input.zig");
    const expected = @embedFile("fixtures/indent_width/expected_tabs.zig");

    const formatted = try reindent(gpa, input, .tab, 4);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
    try format_test_assertions.expectValidZig(formatted);

    const formatted_expected = try reindent(gpa, expected, .tab, 4);
    defer gpa.free(formatted_expected);
    try format_test_assertions.expectIdempotent(expected, formatted_expected);
}

/// Leading-whitespace character used per indentation level. Zig's own AST
/// renderer (`tree.render()`) always emits 4-space indentation, so `.space`
/// at width 4 is the identity case (see `reindent`).
pub const Style = enum {
    space,
    tab,

    /// Config / diagnostic label for this style.
    pub fn label(self: Style) []const u8 {
        return switch (self) {
            .space => "space",
            .tab => "tab",
        };
    }

    /// Parses TOML / schema spellings (`space`, `tab`).
    pub fn fromConfigString(text: []const u8) ?Style {
        if (mem.eql(u8, text, "space")) return .space;
        if (mem.eql(u8, text, "tab")) return .tab;
        return null;
    }
};

/// Re-indents source from the standard 4-space width to `style`/`width`.
///
/// Only leading whitespace is affected. Each group of 4 consecutive leading
/// spaces (one indent level) becomes either `width` spaces or a single tab,
/// depending on `style`. `width` is ignored when `style == .tab` -- a tab
/// has no meaningful "width" in the emitted bytes, only in how a reader's
/// editor chooses to display it. A partial group (leftover spaces that
/// don't complete a full indent level) can't be represented as a fractional
/// tab, so it's always preserved as plain spaces, regardless of `style`.
pub fn reindent(gpa: Allocator, input: []const u8, style: Style, width: u8) Allocator.Error![]u8 {
    std.debug.assert(width > 0);
    if (style == .space and width == 4) {
        return gpa.dupe(u8, input);
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    const estimate: usize = if (style == .space and width > 4)
        input.len + input.len / 4
    else
        input.len;
    try output.ensureTotalCapacity(gpa, estimate);

    var line_start: usize = 0;
    while (line_start < input.len) {
        const line_end = mem.indexOfScalar(u8, input[line_start..], '\n') orelse input.len - line_start;
        const full_line = input[line_start .. line_start + line_end];
        line_start += line_end + 1;

        const leading = leadingSpaces(full_line);
        const levels = leading / 4;
        const remainder = leading % 4;

        var i: usize = 0;
        while (i < levels) : (i += 1) {
            switch (style) {
                .space => {
                    var j: u8 = 0;
                    while (j < width) : (j += 1) {
                        try output.append(gpa, ' ');
                    }
                },
                .tab => try output.append(gpa, '\t'),
            }
        }

        i = 0;
        while (i < remainder) : (i += 1) {
            try output.append(gpa, ' ');
        }

        try output.appendSlice(gpa, full_line[leading..]);
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
