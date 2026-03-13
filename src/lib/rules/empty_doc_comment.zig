const std = @import("std");
const Ast = std.zig.Ast;
const Diagnostic = @import("../Diagnostic.zig");
const Severity = @import("../Severity.zig");

const rule_name = "empty_doc_comment";

pub fn check(
    tree: *const Ast,
    severity: Severity.Level,
    file: []const u8,
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    _ = msg_allocator;
    if (!severity.isActive()) return;
    const tags = tree.tokens.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag == .doc_comment or tag == .container_doc_comment) {
            const slice = tree.tokenSlice(@intCast(i));
            if (isEmptyDocComment(slice)) {
                const loc = tree.tokenLocation(0, @intCast(i));
                try diagnostics.append(allocator, .{
                    .rule = rule_name,
                    .severity = severity,
                    .message = "doc comment is empty",
                    .file = file,
                    .line = loc.line + 1,
                    .column = loc.column + 1,
                });
            }
        }
    }
}

fn isEmptyDocComment(slice: []const u8) bool {
    const prefix: []const u8 = if (std.mem.startsWith(u8, slice, "//!"))
        "//!"
    else if (std.mem.startsWith(u8, slice, "///"))
        "///"
    else
        return false;

    const rest = slice[prefix.len..];
    return std.mem.trim(u8, rest, " \t\r\n").len == 0;
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

    try check(&tree, .warn, "<test>", base, msg_arena.allocator(), &diagnostics);
    return .{ .msg_arena = msg_arena, .items = diagnostics };
}

test "detects empty /// comment" {
    var r = try runCheck(
        \\///
        \\pub fn foo() void {}
    );
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
    try std.testing.expectEqualStrings(rule_name, r.items.items[0].rule);
}

test "detects empty /// with spaces" {
    var r = try runCheck("///   \npub fn foo() void {}");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
}

test "no diagnostic for non-empty doc comment" {
    var r = try runCheck(
        \\/// Does something.
        \\pub fn foo() void {}
    );
    defer r.deinit();
    try std.testing.expectEqual(0, r.items.items.len);
}

test "detects empty //! comment" {
    var r = try runCheck("//!");
    defer r.deinit();
    try std.testing.expectEqual(1, r.items.items.len);
}
