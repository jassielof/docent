//! The `trailing_blank_doc_comment` namespace flags doc comment blocks that end with blank lines.

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const utils = @import("../utils.zig");

const rule_name = "trailing_blank_doc_comment";

/// Walks `tree` and appends diagnostics for doc comments with trailing blank lines.
pub fn check(
    tree: *const Ast,
    severity_level: severity.Level,
    file: []const u8,
    module_name: ?[]const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (!severity_level.isActive()) return;
    const tags = tree.tokens.items(.tag);
    var i: usize = 0;
    while (i < tags.len) {
        const tag = tags[i];
        if (tag != .doc_comment and tag != .container_doc_comment) {
            i += 1;
            continue;
        }

        const block_start = i;
        while (i < tags.len and tags[i] == tag) : (i += 1) {}

        const block_end = i;
        const documented_first: Ast.TokenIndex = @intCast(block_end);

        if (findFirstTrailingBlank(tree, block_start, block_end)) |blank_tok| {
            const slice = tree.tokenSlice(blank_tok);
            const loc = tree.tokenLocation(0, blank_tok);
            const subject = if (tag == .container_doc_comment)
                try utils.ownedSubject(msg_allocator, .module, utils.moduleDisplayName(file, module_name))
            else
                try utils.resolveDocCommentSubject(tree, documented_first, file, module_name, msg_allocator);
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity_level = severity_level,
                .subject = subject,
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
                .source_line = try utils.dupSourceLine(tree, blank_tok, msg_allocator),
                .symbol_len = slice.len,
            });
        }
    }
}

fn findFirstTrailingBlank(
    tree: *const Ast,
    block_start: usize,
    block_end: usize,
) ?Ast.TokenIndex {
    var last_non_empty: ?usize = null;
    var tok: usize = block_start;
    while (tok < block_end) : (tok += 1) {
        const slice = tree.tokenSlice(@intCast(tok));
        if (!utils.isEmptyDocCommentLine(slice)) last_non_empty = tok;
    }

    const after_content = (last_non_empty orelse return null) + 1;
    if (after_content >= block_end) return null;

    var trailing = after_content;
    while (trailing < block_end) : (trailing += 1) {
        const slice = tree.tokenSlice(@intCast(trailing));
        if (!utils.isEmptyDocCommentLine(slice)) return null;
    }

    return @intCast(after_content);
}

const TestResult = struct {
    msg_arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic),

    fn deinit(self: *TestResult) void {
        self.msg_arena.deinit();
        self.items.deinit(std.testing.allocator);
    }
};

fn runCheck(source: [:0]const u8) !TestResult {
    const base = std.testing.allocator;
    var msg_arena = std.heap.ArenaAllocator.init(base);
    errdefer msg_arena.deinit();

    var tree = try std.zig.Ast.parse(base, source, .zig);
    defer tree.deinit(base);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(base);

    try check(&tree, .warn, "<test>", null, base, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "detects trailing blank /// line" {
    var r = try runCheck("/// Does something.\n///\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expectEqual(.function, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("foo", r.items.items[0].subject.?.name);
}

test "detects multiple trailing blank /// lines once" {
    var r = try runCheck("/// Text.\n///\n///   \npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(@as(usize, 2), r.items.items[0].line);
}

test "no diagnostic for internal blank lines" {
    var r = try runCheck("/// This should\n///\n/// be valid\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "no diagnostic when block ends with content" {
    var r = try runCheck("/// Does something.\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "no diagnostic for fully blank block" {
    var r = try runCheck("///\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "detects trailing blank on //! module doc" {
    var r = try runCheck("//! Module docs.\n//!\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.module, r.items.items[0].subject.?.kind);
}

test "detects trailing blank /// on enum enumerator" {
    var r = try runCheck(
        \\pub const Color = enum {
        \\    /// Red.
        \\    ///
        \\    red,
        \\};
        ,
    );
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.enumerator, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("red", r.items.items[0].subject.?.name);
}
