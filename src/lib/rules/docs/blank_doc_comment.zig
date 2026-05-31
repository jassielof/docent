//! The `blank_doc_comment` namespace flags doc comments that are blank or whitespace-only.

const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../../Diagnostic.zig");
const severity = @import("../../severity.zig");
const utils = @import("../utils.zig");

const rule_name = "blank_doc_comment";

/// Walks `tree` and appends diagnostics for vacuous doc comments.
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
        var all_empty = true;

        while (i < tags.len and tags[i] == tag) : (i += 1) {
            const tok: Ast.TokenIndex = @intCast(i);
            const slice = tree.tokenSlice(tok);
            if (!utils.isEmptyDocCommentLine(slice)) all_empty = false;
        }

        if (all_empty) {
            const tok: Ast.TokenIndex = @intCast(block_start);
            const slice = tree.tokenSlice(tok);
            const loc = tree.tokenLocation(0, tok);
            const subject = if (tag == .container_doc_comment)
                try utils.ownedSubject(msg_allocator, .module, utils.moduleDisplayName(file, module_name))
            else
                try utils.resolveDocCommentSubject(tree, @intCast(i), file, module_name, msg_allocator);
            try diagnostics.append(allocator, .{
                .rule = rule_name,
                .severity_level = severity_level,
                .subject = subject,
                .file = file,
                .line = loc.line + 1,
                .column = loc.column + 1,
                .source_line = try utils.dupSourceLine(tree, tok, msg_allocator),
                .symbol_len = slice.len,
            });
        }
    }
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

test "detects blank /// comment" {
    var r = try runCheck("///\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
    try std.testing.expectEqual(.function, r.items.items[0].subject.?.kind);
    try std.testing.expectEqualStrings("foo", r.items.items[0].subject.?.name);
    try std.testing.expectEqual(@as(usize, 3), r.items.items[0].symbol_len);
}

test "detects blank /// on enum enumerator" {
    var r = try runCheck(
        \\pub const Color = enum {
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

test "detects blank /// with spaces" {
    var r = try runCheck("///   \npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
}

test "no diagnostic for non-empty doc comment" {
    var r = try runCheck("/// Does something.\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "detects blank //! comment" {
    var r = try runCheck("//!");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqual(.module, r.items.items[0].subject.?.kind);
}

test "detects fully blank multiline /// comment block once" {
    var r = try runCheck("///\n///   \npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
}

test "no diagnostic for multiline block with at least one non-empty line" {
    var r = try runCheck("/// This should\n///\n/// be valid\npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}
