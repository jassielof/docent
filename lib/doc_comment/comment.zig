//! Parsing utilities for Zig doc-comment text (`///` and `//!` lines).
//!
//! Operates on comment source text and token blocks, not on declaration
//! structure (see `extract.zig`).

const std = @import("std");
const Ast = std.zig.Ast;

/// Text after the `///` or `//!` prefix, trimmed of leading horizontal whitespace.
pub fn lineBody(slice: []const u8) []const u8 {
    const prefix: []const u8 = if (std.mem.startsWith(u8, slice, "//!"))
        "//!"
    else if (std.mem.startsWith(u8, slice, "///"))
        "///"
    else
        return slice;

    return std.mem.trim(u8, slice[prefix.len..], " \t");
}

/// True when a `///` or `//!` token has no text after the doc-comment prefix.
pub fn isEmptyLine(slice: []const u8) bool {
    const prefix: []const u8 = if (std.mem.startsWith(u8, slice, "//!"))
        "//!"
    else if (std.mem.startsWith(u8, slice, "///"))
        "///"
    else
        return false;

    const rest = slice[prefix.len..];
    return std.mem.trim(u8, rest, " \t\r\n").len == 0;
}

/// The first paragraph of a contiguous doc-comment block (lines until a blank `///`/`//!` line).
pub const Paragraph = struct {
    text: []const u8,
    last_line_token: ?Ast.TokenIndex,
};

/// Collects the first paragraph from `block_start` (inclusive) to `block_end` (exclusive).
pub fn firstParagraph(
    tree: *const Ast,
    block_start: usize,
    block_end: usize,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!Paragraph {
    var paragraph = std.ArrayList(u8).empty;
    defer paragraph.deinit(allocator);

    var last_line_token: ?Ast.TokenIndex = null;

    var tok: usize = block_start;
    while (tok < block_end) : (tok += 1) {
        const token: Ast.TokenIndex = @intCast(tok);
        const slice = tree.tokenSlice(token);
        if (isEmptyLine(slice)) break;

        const body = lineBody(slice);
        if (body.len == 0) continue;

        if (paragraph.items.len > 0) try paragraph.append(allocator, ' ');
        try paragraph.appendSlice(allocator, body);
        last_line_token = token;
    }

    return .{
        .text = try paragraph.toOwnedSlice(allocator),
        .last_line_token = last_line_token,
    };
}

/// Collects whitespace-separated words from the first paragraph; returns its first token for reporting.
pub fn summaryWords(
    tree: *const Ast,
    block_start: usize,
    block_end: usize,
    allocator: std.mem.Allocator,
    words: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!?Ast.TokenIndex {
    var report_tok: ?Ast.TokenIndex = null;
    var tok: usize = block_start;
    while (tok < block_end) : (tok += 1) {
        const token: Ast.TokenIndex = @intCast(tok);
        const slice = tree.tokenSlice(token);
        if (isEmptyLine(slice)) break;

        const body = lineBody(slice);
        if (body.len == 0) continue;
        if (report_tok == null) report_tok = token;

        var it = std.mem.tokenizeAny(u8, body, " \t");
        while (it.next()) |word| try words.append(allocator, word);
    }
    return report_tok;
}

/// True when `text` ends with `.`, `!`, or `?` (after trimming trailing whitespace).
pub fn endsWithTerminalPunctuation(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return true;
    return switch (trimmed[trimmed.len - 1]) {
        '.', '!', '?' => true,
        else => false,
    };
}

/// Returns the first blank line after the last non-empty line in a doc-comment block, if any.
pub fn firstTrailingBlankLine(
    tree: *const Ast,
    block_start: usize,
    block_end: usize,
) ?Ast.TokenIndex {
    var last_non_empty: ?usize = null;
    var tok: usize = block_start;
    while (tok < block_end) : (tok += 1) {
        const slice = tree.tokenSlice(@intCast(tok));
        if (!isEmptyLine(slice)) last_non_empty = tok;
    }

    const after_content = (last_non_empty orelse return null) + 1;
    if (after_content >= block_end) return null;

    var trailing = after_content;
    while (trailing < block_end) : (trailing += 1) {
        const slice = tree.tokenSlice(@intCast(trailing));
        if (!isEmptyLine(slice)) return null;
    }

    return @intCast(after_content);
}

test "lineBody strips doc prefixes" {
    try std.testing.expectEqualStrings("foo", lineBody("/// foo"));
    try std.testing.expectEqualStrings("bar", lineBody("//!\tbar"));
    try std.testing.expectEqualStrings("plain", lineBody("plain"));
}

test "isEmptyLine detects blank doc lines" {
    try std.testing.expect(isEmptyLine("///"));
    try std.testing.expect(isEmptyLine("//!  "));
    try std.testing.expect(!isEmptyLine("/// text"));
}

test "firstParagraph stops at blank line" {
    const source =
        \\/// Line one
        \\///
        \\/// Line three
        \\pub fn foo() void {}
    ++ "\x00";
    var tree = try std.zig.Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    const para = try firstParagraph(&tree, 0, 3, std.testing.allocator);
    defer std.testing.allocator.free(para.text);
    try std.testing.expectEqualStrings("Line one", para.text);
    try std.testing.expectEqual(@as(?Ast.TokenIndex, 0), para.last_line_token);
}

test "endsWithTerminalPunctuation" {
    try std.testing.expect(endsWithTerminalPunctuation("Hello."));
    try std.testing.expect(endsWithTerminalPunctuation("Watch out!"));
    try std.testing.expect(!endsWithTerminalPunctuation("No mark"));
}
